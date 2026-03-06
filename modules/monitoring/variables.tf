variable "location" {
  description = "Azure region"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "log_analytics_name" {
  description = "Log Analytics Workspace name"
  type        = string
}

variable "monitor_workspace_name" {
  description = "Azure Monitor Workspace name (Managed Prometheus)"
  type        = string
}

variable "app_insights_name" {
  description = "Application Insights name"
  type        = string
}

variable "enable_sentinel" {
  description = "Enable Microsoft Sentinel on Log Analytics Workspace"
  type        = bool
  default     = false
}

variable "enable_mcas" {
  description = "Enable Sentinel MCAS Data Connector (Microsoft 365 E5 / EMS E5 라이선스 필요)"
  type        = bool
  default     = false
}

variable "enable_grafana" {
  description = "Enable Azure Managed Grafana for Prometheus visualization"
  type        = bool
  default     = true
}

variable "grafana_name" {
  description = "Azure Managed Grafana instance name (globally unique)"
  type        = string
}

variable "log_retention_days" {
  description = "Log Analytics Workspace retention in days"
  type        = number
  default     = 30
}

variable "grafana_public_access" {
  description = "Enable public network access for Azure Managed Grafana"
  type        = bool
  default     = true
}

variable "grafana_sku" {
  description = "Azure Managed Grafana SKU (Standard or Essential)"
  type        = string
  default     = "Standard"
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
