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

variable "enable_private_endpoint" {
  description = "ACR Private Endpoint 활성화 (Standard/Premium SKU 필요 — Basic은 미지원)"
  type        = bool
  default     = false
}

variable "pe_subnet_id" {
  description = "Private Endpoint subnet ID (enable_private_endpoint = true 시 필수)"
  type        = string
  default     = ""
}

variable "vnet_ids" {
  description = "VNet ID map — ACR Private DNS Zone 링크 생성용"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
