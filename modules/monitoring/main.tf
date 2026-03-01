# ============================================================
# modules/monitoring/main.tf
# Log Analytics + Azure Monitor Workspace (Managed Prometheus)
# + Application Insights + Azure Sentinel
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

# ============================================================
# Azure Sentinel (Microsoft Sentinel)
# Log Analytics Workspace에 Sentinel 솔루션 연결.
# Defender for Containers / Flux / Karpenter 로그 → AI 위협 탐지
# ============================================================

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "sentinel" {
  count = var.enable_sentinel ? 1 : 0

  workspace_id = azurerm_log_analytics_workspace.law.id
}

# Sentinel Data Connector — Azure Active Directory
resource "azurerm_sentinel_data_connector_azure_active_directory" "aad" {
  count = var.enable_sentinel ? 1 : 0

  name                       = "dc-aad"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.sentinel[0].workspace_id
}

# Sentinel Data Connector — Microsoft Cloud App Security (MCAS)
resource "azurerm_sentinel_data_connector_microsoft_cloud_app_security" "mcas" {
  count = var.enable_sentinel ? 1 : 0

  name                       = "dc-mcas"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.sentinel[0].workspace_id
}
