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
  resource_group_name           = var.rg_cluster[each.key]
  kind                          = "Linux"
  # true: Managed Prometheus Agent가 DCE HTTP 엔드포인트로 메트릭 push 가능
  # false로 두면 Private Endpoint 없이는 수집 불가 (기본 비활성화 상태에서 수집 안 됨)
  public_network_access_enabled = true

  tags = var.tags
}

# ---- Data Collection Rule (per cluster) ----
resource "azurerm_monitor_data_collection_rule" "prometheus" {
  for_each = var.clusters

  name                        = "MSProm-DCR-${var.location}-${each.key}"
  location                    = var.location
  resource_group_name         = var.rg_cluster[each.key]
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
