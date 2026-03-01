variable "location" {
  type = string
}

variable "rg_common" {
  type = string
}

variable "log_analytics_name" {
  type = string
}

variable "monitor_workspace_name" {
  type = string
}

variable "app_insights_name" {
  type = string
}

variable "enable_sentinel" {
  description = "Enable Microsoft Sentinel on Log Analytics Workspace"
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

variable "tags" {
  type    = map(string)
  default = {}
}
