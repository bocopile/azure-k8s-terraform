variable "location" {
  description = "Azure region"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "name" {
  description = "ACR name (globally unique, alphanumeric)"
  type        = string
}

variable "sku" {
  description = "ACR SKU (Basic, Standard, or Premium)"
  type        = string
  default     = "Basic"
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace resource ID for ACR Diagnostic Settings"
  type        = string
  default     = ""
}

variable "enable_diagnostics" {
  description = "Enable Diagnostic Settings to Log Analytics Workspace"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
