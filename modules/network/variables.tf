variable "location" {
  description = "Azure region"
  type        = string
}

variable "prefix" {
  description = "Naming prefix for all resources"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "vnets" {
  description = "VNet definitions: key=name, value={cidr}"
  type = map(object({
    cidr = string
  }))
}

variable "aks_subnets" {
  description = "AKS subnet CIDRs per VNet key"
  type        = map(string)
}

variable "bastion_subnet_cidr" {
  description = "AzureBastionSubnet CIDR (mgmt VNet only)"
  type        = string
}

variable "jumpbox_subnet_cidr" {
  description = "Jumpbox subnet CIDR (mgmt VNet only)"
  type        = string
}

variable "pe_subnet_cidr" {
  description = "Private Endpoint subnet CIDR (mgmt VNet, ARCHITECTURE.md §5.6)"
  type        = string
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
