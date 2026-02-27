# ============================================================
# modules/keyvault/main.tf
# Azure Key Vault — Standard SKU, RBAC mode, Private Endpoint
# ARCHITECTURE.md §5.6: Private Endpoint 필수
# ============================================================

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                = var.name
  location            = var.location
  resource_group_name = var.rg_common
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  # RBAC authorization (access policy 방식 미사용, 최신 권장)
  enable_rbac_authorization = true

  soft_delete_retention_days = 90
  purge_protection_enabled   = false # Demo: 재생성 편의를 위해 비활성

  # Private Endpoint 구성 후 공개 접근 차단 (ARCHITECTURE.md §5.6)
  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices" # Terraform apply 시 AzureServices 우회 허용
  }

  tags = var.tags
}

# 배포 주체에 Key Vault Administrator 부여
# (Terraform이 시크릿/키 작성에 필요)
resource "azurerm_role_assignment" "deployer_kv_admin" {
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "Key Vault Administrator"
  scope                = azurerm_key_vault.kv.id
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
