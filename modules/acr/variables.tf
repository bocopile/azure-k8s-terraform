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

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
