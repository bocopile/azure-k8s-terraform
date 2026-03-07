# ============================================================
# modules/backup/main.tf
# Azure Backup Vault + AKS Backup Policy
# ============================================================

resource "azurerm_data_protection_backup_vault" "vault" {
  name                = var.vault_name
  location            = var.location
  resource_group_name = var.rg_common

  datastore_type = "VaultStore"
  redundancy     = "ZoneRedundant"

  # soft_delete: "On" = 삭제 후 데이터 보존 (prod 권장)
  # "Off" = 즉시 삭제 (demo/dev 환경 cleanup 편의)
  # 주의: "On" 상태에서 tofu destroy 시 BackupInstance 먼저 제거 필요
  soft_delete = var.enable_soft_delete ? "On" : "Off"

  tags = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# ============================================================
# AKS Backup Policy — Daily at 02:00 UTC, 7-day retention
# ============================================================

# ============================================================
# Backup Staging Storage Account
# AKS Backup Extension이 백업 메타데이터/아티팩트를 임시 저장하는 Blob Storage
# ============================================================

resource "azurerm_storage_account" "backup" {
  name                     = var.backup_storage_account_name
  location                 = var.location
  resource_group_name      = var.rg_common
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  tags = var.tags
}

resource "azurerm_storage_container" "backup" {
  for_each = var.cluster_ids

  name               = "bkp-${each.key}"
  storage_account_id = azurerm_storage_account.backup.id
}

resource "azurerm_data_protection_backup_policy_kubernetes_cluster" "aks_policy" {
  name                = var.policy_name
  resource_group_name = var.rg_common
  vault_name          = azurerm_data_protection_backup_vault.vault.name

  backup_repeating_time_intervals = ["R/2024-01-01T02:00:00+00:00/P1D"]

  default_retention_rule {
    life_cycle {
      duration        = var.backup_retention_duration
      data_store_type = "OperationalStore"
    }
  }
}

# ============================================================
# RBAC — Backup Vault MSI 권한 부여
# ============================================================

# Backup Vault MSI → Storage Account: 백업 데이터 읽기/쓰기
resource "azurerm_role_assignment" "vault_storage_blob" {
  scope                = azurerm_storage_account.backup.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_protection_backup_vault.vault.identity[0].principal_id
}

# Backup Vault MSI → 각 클러스터 RG: 스냅샷 관리 (Snapshot 생성/삭제)
resource "azurerm_role_assignment" "vault_cluster_rg_contributor" {
  for_each = var.cluster_rg_ids

  scope                = each.value
  role_definition_name = "Contributor"
  principal_id         = azurerm_data_protection_backup_vault.vault.identity[0].principal_id
}

# Kubelet Identity → 각 클러스터 RG: 디스크 스냅샷 생성 권한
resource "azurerm_role_assignment" "kubelet_snapshot_contributor" {
  for_each = var.cluster_rg_ids

  scope                = each.value
  role_definition_name = "Contributor"
  principal_id         = var.kubelet_object_ids[each.key]
}

# ============================================================
# AKS Backup Extension (per cluster)
# Terraform으로 Extension을 관리 — 09-backup-extension.sh 불필요
# ============================================================

resource "azurerm_kubernetes_cluster_extension" "backup" {
  for_each = var.cluster_ids

  name           = "azure-aks-backup"
  cluster_id     = each.value
  extension_type = "microsoft.dataprotection.kubernetes"
  release_train  = "stable"
  # auto_upgrade_minor_version_enabled: azurerm ~4.14 미지원 — 기본 동작(자동 업그레이드) 사용

  configuration_settings = {
    "configuration.backupStorageLocation.bucket"                = azurerm_storage_container.backup[each.key].name
    "configuration.backupStorageLocation.config.storageAccount" = azurerm_storage_account.backup.name
    "configuration.backupStorageLocation.config.resourceGroup"  = azurerm_storage_account.backup.resource_group_name
    "configuration.backupStorageLocation.config.subscriptionId" = var.subscription_id
    "credentials.tenantId"                                      = var.tenant_id
  }

  depends_on = [
    azurerm_role_assignment.vault_storage_blob,
    azurerm_role_assignment.vault_cluster_rg_contributor,
    azurerm_role_assignment.kubelet_snapshot_contributor,
  ]
}

# Backup Extension aksAssignedIdentity → 각 클러스터 RG: 스냅샷 Contributor 권한
# Extension 설치 후 동적으로 생성되는 MSI에 역할 부여
resource "azurerm_role_assignment" "extension_snapshot_contributor" {
  for_each = var.cluster_rg_ids

  scope                = each.value
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster_extension.backup[each.key].aks_assigned_identity[0].principal_id
}

# ============================================================
# Trusted Access Role Binding (per cluster)
# Backup Vault MSI가 AKS 클러스터에 직접 접근하기 위해 필수.
# 없으면 BackupInstance가 ProtectionError 상태로 남음.
# ============================================================

resource "azurerm_kubernetes_cluster_trusted_access_role_binding" "backup" {
  for_each = var.cluster_ids

  name                  = "tarb-backup-${each.key}"
  kubernetes_cluster_id = each.value
  roles                 = ["Microsoft.DataProtection/backupVaults/backup-operator"]
  source_resource_id    = azurerm_data_protection_backup_vault.vault.id

  depends_on = [azurerm_data_protection_backup_vault.vault]
}

# ============================================================
# AKS Backup Instance (per cluster)
# Vault + Policy + Extension + Trusted Access 모두 준비된 후 연결
# ============================================================

resource "azurerm_data_protection_backup_instance_kubernetes_cluster" "aks" {
  for_each = var.cluster_ids

  name     = "bi-aks-${each.key}"
  location = var.location
  vault_id = azurerm_data_protection_backup_vault.vault.id

  backup_policy_id             = azurerm_data_protection_backup_policy_kubernetes_cluster.aks_policy.id
  kubernetes_cluster_id        = each.value
  snapshot_resource_group_name = var.cluster_rg_names[each.key]
  # kubernetes_cluster_extension_id: azurerm ~4.14 미지원 속성 — Extension 설치 후 자동 연결됨

  backup_datasource_parameters {
    # 모든 네임스페이스 포함 (excluded_namespaces로 제외 가능)
    excluded_namespaces              = []
    excluded_resource_types          = []
    cluster_scoped_resources_enabled = true
    included_namespaces              = []
    included_resource_types          = []
    label_selectors                  = []
    volume_snapshot_enabled          = true
  }

  depends_on = [
    azurerm_kubernetes_cluster_extension.backup,
    azurerm_kubernetes_cluster_trusted_access_role_binding.backup,
    azurerm_role_assignment.vault_cluster_rg_contributor,
    azurerm_role_assignment.vault_storage_blob,
    azurerm_role_assignment.kubelet_snapshot_contributor,
    azurerm_role_assignment.extension_snapshot_contributor,
  ]
}
