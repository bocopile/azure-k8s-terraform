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

resource "azurerm_data_protection_backup_policy_kubernetes_cluster" "aks_policy" {
  name                            = var.policy_name
  resource_group_name             = var.rg_common
  vault_name                      = azurerm_data_protection_backup_vault.vault.name

  backup_repeating_time_intervals = ["R/2024-01-01T02:00:00+00:00/P1D"]

  default_retention_rule {
    life_cycle {
      duration        = "P7D"
      data_store_type = "OperationalStore"
    }
  }
}
