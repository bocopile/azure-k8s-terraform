# ============================================================
# modules/aks/prometheus.tf
# Managed Prometheus — Data Collection Endpoint / Rule / Association
# AKS monitor_metrics {} 블록만으로는 메트릭이 Azure Monitor Workspace에
# 전달되지 않으므로, DCE + DCR + DCRA 리소스를 명시적으로 생성해야 합니다.
# ============================================================

# ---- Data Collection Endpoint (per cluster) ----
resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  for_each = var.clusters

  name                          = "MSProm-DCE-${var.location}-${each.key}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.cluster[each.key].name
  kind                          = "Linux"
  public_network_access_enabled = false

  tags = var.tags
}

# ---- Data Collection Rule (per cluster) ----
resource "azurerm_monitor_data_collection_rule" "prometheus" {
  for_each = var.clusters

  name                        = "MSProm-DCR-${var.location}-${each.key}"
  location                    = var.location
  resource_group_name         = azurerm_resource_group.cluster[each.key].name
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus[each.key].id
  kind                        = "Linux"

  destinations {
    monitor_account {
      monitor_account_id = var.monitor_workspace_id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      streams = ["Microsoft-PrometheusMetrics"]
      name    = "PrometheusDataSource"
    }
  }

  tags = var.tags
}

# ---- Data Collection Rule Association (per cluster) ----
resource "azurerm_monitor_data_collection_rule_association" "prometheus" {
  for_each = var.clusters

  name                    = "MSProm-${each.key}"
  target_resource_id      = azurerm_kubernetes_cluster.aks[each.key].id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus[each.key].id
}
