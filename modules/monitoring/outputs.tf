output "log_analytics_workspace_id" {
  description = "Log Analytics Workspace resource ID"
  value       = azurerm_log_analytics_workspace.law.id
}

output "log_analytics_workspace_key" {
  description = "Log Analytics Workspace primary shared key"
  value       = azurerm_log_analytics_workspace.law.primary_shared_key
  sensitive   = true
}

output "monitor_workspace_id" {
  description = "Azure Monitor Workspace resource ID (Managed Prometheus)"
  value       = azurerm_monitor_workspace.mon.id
}

output "app_insights_connection_string" {
  description = "Application Insights connection string"
  value       = azurerm_application_insights.appi.connection_string
  sensitive   = true
}

output "app_insights_instrumentation_key" {
  description = "Application Insights instrumentation key"
  value       = azurerm_application_insights.appi.instrumentation_key
  sensitive   = true
}

output "log_analytics_workspace_guid" {
  description = "Log Analytics Workspace GUID (for Traffic Analytics, NSG Flow Logs)"
  value       = azurerm_log_analytics_workspace.law.workspace_id
}

output "grafana_endpoint" {
  description = "Azure Managed Grafana endpoint URL"
  value       = var.enable_grafana ? azurerm_dashboard_grafana.grafana[0].endpoint : ""
}
