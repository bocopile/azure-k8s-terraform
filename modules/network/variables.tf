variable "location" {
  description = "Azure region"
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

variable "enable_private_cluster" {
  description = "true = AKS Private Cluster용 Private DNS Zone 생성"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
