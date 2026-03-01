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

# ============================================================
# Azure Managed Grafana — Prometheus 시각화 대시보드
# Azure Monitor Workspace (Managed Prometheus) 데이터 소스 자동 연결
# ============================================================

resource "azurerm_dashboard_grafana" "grafana" {
  count = var.enable_grafana ? 1 : 0

  name                              = var.grafana_name
  location                          = var.location
  resource_group_name               = var.rg_common
  grafana_major_version             = "10"
  sku                               = "Standard"
  public_network_access_enabled     = true
  zone_redundancy_enabled           = false

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.mon.id
  }

  tags = var.tags
}

# Grafana MSI → Monitor Workspace에 Monitoring Reader 권한
resource "azurerm_role_assignment" "grafana_monitoring_reader" {
  count = var.enable_grafana ? 1 : 0

  scope                = azurerm_monitor_workspace.mon.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_dashboard_grafana.grafana[0].identity[0].principal_id
}

# Grafana MSI → Log Analytics에 Log Analytics Reader 권한
resource "azurerm_role_assignment" "grafana_law_reader" {
  count = var.enable_grafana ? 1 : 0

  scope                = azurerm_log_analytics_workspace.law.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_dashboard_grafana.grafana[0].identity[0].principal_id
}

# ============================================================
# Activity Log → Log Analytics (구독 레벨 Diagnostic Setting)
#
# Azure 구독의 Activity Log는 기본 90일만 보존.
# LAW로 전송하면 장기 보존 + KQL 쿼리 + Sentinel 분석 가능.
# ============================================================

data "azurerm_subscription" "current" {}

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "diag-activity-to-law"
  target_resource_id         = "/subscriptions/${data.azurerm_subscription.current.subscription_id}"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log { category = "Administrative" }
  enabled_log { category = "Security" }
  enabled_log { category = "Alert" }
  enabled_log { category = "Policy" }
  enabled_log { category = "Autoscale" }
  enabled_log { category = "ResourceHealth" }
  enabled_log { category = "Recommendation" }
  enabled_log { category = "ServiceHealth" }
}
