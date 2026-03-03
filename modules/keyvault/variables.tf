variable "location" {
  description = "Azure region"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "name" {
  description = "Key Vault name (globally unique)"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD Tenant ID"
  type        = string
}

variable "pe_subnet_id" {
  description = "Private Endpoint 전용 서브넷 ID (ARCHITECTURE.md §5.6)"
  type        = string
}

variable "vnet_ids" {
  description = "VNet IDs — Private DNS Zone을 전체 VNet에 연결 (peered VNet 포함)"
  type        = map(string)
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for Key Vault diagnostic settings"
  type        = string
  default     = ""
}

variable "sku_name" {
  description = "Key Vault SKU (standard or premium)"
  type        = string
  default     = "standard"
}

variable "purge_protection" {
  description = "Enable Key Vault purge protection (true for prod)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
