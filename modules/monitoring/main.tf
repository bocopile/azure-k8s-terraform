# ============================================================
# modules/monitoring/main.tf
# Log Analytics + Azure Monitor Workspace (Managed Prometheus)
# + Application Insights
# ============================================================

# ============================================================
# Log Analytics Workspace (Container Insights + logs)
# ============================================================

resource "azurerm_log_analytics_workspace" "law" {
  name                = var.log_analytics_name
  location            = var.location
  resource_group_name = var.rg_common
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = var.tags
}

# ============================================================
# Azure Monitor Workspace (Managed Prometheus)
# ============================================================

resource "azurerm_monitor_workspace" "mon" {
  name                = var.monitor_workspace_name
  location            = var.location
  resource_group_name = var.rg_common
  tags                = var.tags
}

# ============================================================
# Application Insights (connected to Log Analytics)
# ============================================================

resource "azurerm_application_insights" "appi" {
  name                = var.app_insights_name
  location            = var.location
  resource_group_name = var.rg_common
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"

  tags = var.tags
}
