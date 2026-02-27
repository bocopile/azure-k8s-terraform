variable "location" {
  type = string
}

variable "rg_common" {
  type = string
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

variable "tags" {
  type    = map(string)
  default = {}
}
