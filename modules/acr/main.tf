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
}
