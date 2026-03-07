# ============================================================
# modules/acr/main.tf
# Azure Container Registry — Basic SKU
# AcrPull role is assigned in modules/identity/ (kubelet identity)
# ============================================================

resource "azurerm_container_registry" "acr" {
  name                = var.name
  location            = var.location
  resource_group_name = var.rg_common
  sku                 = var.sku

  # Admin credentials disabled — use Workload Identity / Kubelet Identity
  admin_enabled = false

  tags = var.tags
}

# ============================================================
# ACR Diagnostic Settings → Log Analytics Workspace
# 감사 로그, 레이어 push/pull 이벤트 수집
# ============================================================

resource "azurerm_monitor_diagnostic_setting" "acr" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag-acr-to-law"
  target_resource_id         = azurerm_container_registry.acr.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "ContainerRegistryRepositoryEvents" }
  enabled_log { category = "ContainerRegistryLoginEvents" }

  enabled_metric {
    category = "AllMetrics"
  }

  timeouts {
    create = "10m"
    update = "10m"
    delete = "5m"
    read   = "5m"
  }
}

# ============================================================
# ACR Private Endpoint (Standard/Premium SKU 전용)
# Basic SKU는 Private Endpoint 미지원 → enable_private_endpoint = false 유지
# DNS zone: privatelink.azurecr.io / subresource: registry
# ============================================================

resource "azurerm_private_dns_zone" "acr" {
  count = var.enable_private_endpoint ? 1 : 0

  name                = "privatelink.azurecr.io"
  resource_group_name = var.rg_common
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  for_each = var.enable_private_endpoint ? var.vnet_ids : {}

  name                  = "dnslink-acr-${each.key}"
  resource_group_name   = var.rg_common
  private_dns_zone_name = azurerm_private_dns_zone.acr[0].name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "acr" {
  count = var.enable_private_endpoint ? 1 : 0

  name                = "pe-${var.name}"
  location            = var.location
  resource_group_name = var.rg_common
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_container_registry.acr.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-acr"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr[0].id]
  }

  tags = var.tags
}
