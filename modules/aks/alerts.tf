# ============================================================
# modules/aks/alerts.tf
# AKS 핵심 메트릭 알림 규칙
#
# Alert 목록:
#   1. Node CPU 사용률 > 90% (Severity 2 — Warning)
#   2. Node Memory 사용률 > 90% (Severity 2 — Warning)
#   3. Pod CrashLoopBackOff 감지 (Severity 1 — Error, KQL 기반)
# ============================================================

# --- Node CPU > 90% ---
resource "azurerm_monitor_metric_alert" "cpu_high" {
  for_each = var.clusters

  name                = "alert-cpu-high-${each.key}"
  resource_group_name = azurerm_resource_group.cluster[each.key].name
  scopes              = [azurerm_kubernetes_cluster.aks[each.key].id]
  description         = "AKS ${each.key}: Node CPU 사용률이 90%를 초과했습니다."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  auto_mitigate       = true

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_cpu_usage_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 90
  }

  tags = var.tags
}

# --- Node Memory > 90% ---
resource "azurerm_monitor_metric_alert" "memory_high" {
  for_each = var.clusters

  name                = "alert-memory-high-${each.key}"
  resource_group_name = azurerm_resource_group.cluster[each.key].name
  scopes              = [azurerm_kubernetes_cluster.aks[each.key].id]
  description         = "AKS ${each.key}: Node Memory 사용률이 90%를 초과했습니다."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  auto_mitigate       = true

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_memory_working_set_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 90
  }

  tags = var.tags
}

# --- Pod CrashLoopBackOff 감지 (KQL Scheduled Query) ---
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "crashloop" {
  for_each = var.clusters

  name                = "alert-crashloop-${each.key}"
  resource_group_name = azurerm_resource_group.cluster[each.key].name
  location            = var.location
  scopes              = [var.log_analytics_workspace_id]
  description         = "AKS ${each.key}: Pod CrashLoopBackOff 감지"
  severity            = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"

  criteria {
    query = <<-KQL
      KubePodInventory
      | where ClusterName == "${azurerm_kubernetes_cluster.aks[each.key].name}"
      | where ContainerStatusReason == "CrashLoopBackOff"
      | summarize CrashCount = count() by bin(TimeGenerated, 5m), Namespace, Name
      | where CrashCount > 0
    KQL

    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  tags                    = var.tags
}
