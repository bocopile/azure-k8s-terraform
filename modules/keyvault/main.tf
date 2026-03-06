# ============================================================
# modules/keyvault/main.tf
# Azure Key Vault — Standard SKU, RBAC mode, Private Endpoint
# ARCHITECTURE.md §5.6: Private Endpoint 필수
#
# ── Destroy 시 주의사항 ──
# Key Vault는 Azure 정책상 삭제 시 soft-deleted 상태로 90일 보존된다.
# 동일 이름으로 재생성이 불가하므로 아래 중 하나로 대응:
#   1) az keyvault purge --name <name>  (purge_protection=false인 경우)
#   2) kv_suffix 변경하여 새 이름으로 재생성
#
# Provider 설정 (main.tf):
#   purge_soft_delete_on_destroy = true   → destroy 시 즉시 purge (현재 설정 — 재배포 편의)
#   purge_soft_delete_on_destroy = false  → destroy 시 purge 안 함 (prod 권장 — 90일 보존)
#
# 상세 절차: DESTROY.md §4 참조
# ============================================================

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                = var.name
  location            = var.location
  resource_group_name = var.rg_common
  tenant_id           = var.tenant_id
  sku_name            = var.sku_name

  # RBAC authorization (access policy 방식 미사용, 최신 권장)
  rbac_authorization_enabled = true

  # Soft delete: Azure 강제 정책 (90일 보존, 비활성화 불가)
  # Purge protection: false=demo (즉시 purge 가능), true=prod (90일 대기)
  soft_delete_retention_days = 90
  purge_protection_enabled   = var.purge_protection

  # public_network_access_enabled:
  #   - allowed_ips 미설정(기본) → false: 완전 Private (PE 전용)
  #   - allowed_ips 설정 시    → true:  방화벽으로 IP 제한 (Terraform 로컬 실행 등)
  # Azure 제약: public_network_access_enabled=false 이면 ip_rules도 무시됨
  public_network_access_enabled = length(var.allowed_ips) > 0 ? true : false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices" # Terraform apply 시 AzureServices 우회 허용
    # Terraform 실행 IP 허용 — 로컬 실행 시 var.allowed_ips에 공인 IP(CIDR) 추가
    # 예: allowed_ips = ["$(curl -s ifconfig.me)/32"]
    ip_rules = var.allowed_ips
  }

  tags = var.tags
}

# 배포 주체에 Key Vault Administrator 부여
# (Terraform이 시크릿/키 작성에 필요)
resource "azurerm_role_assignment" "deployer_kv_admin" {
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "Key Vault Administrator"
  scope                = azurerm_key_vault.kv.id
  principal_type       = "User"
}

# ============================================================
# Private DNS Zone — Key Vault 전용
# ============================================================

resource "azurerm_private_dns_zone" "kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.rg_common
  tags                = var.tags
}

# Private DNS Zone을 모든 VNet(mgmt/app1/app2)에 연결
# → Peered VNet의 Jump VM, AKS 노드에서 동일 DNS 해석
resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  for_each = var.vnet_ids

  name                  = "dnslink-kv-${each.key}"
  resource_group_name   = var.rg_common
  private_dns_zone_name = azurerm_private_dns_zone.kv.name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = var.tags
}

# ============================================================
# Private Endpoint — Key Vault
# ============================================================

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-${var.name}"
  location            = var.location
  resource_group_name = var.rg_common
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }
}

# ============================================================
# Key Vault Diagnostic Settings → Log Analytics
# AuditEvent: 접근·수정 이력 / AzurePolicyEvaluationDetails: 정책 평가
# ============================================================

resource "azurerm_monitor_diagnostic_setting" "kv" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag-${var.name}"
  target_resource_id         = azurerm_key_vault.kv.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "AuditEvent" }
  enabled_log { category = "AzurePolicyEvaluationDetails" }

  enabled_metric { category = "AllMetrics" }
}
