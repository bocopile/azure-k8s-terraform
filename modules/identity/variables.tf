variable "location" {
  description = "Azure region"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "clusters" {
  description = "Cluster definitions map"
  type = map(object({
    has_ingress_pool = bool
    vnet_key         = string
  }))
}

variable "acr_id" {
  description = "Azure Container Registry resource ID"
  type        = string
}

variable "vnet_ids" {
  description = "VNet resource IDs by key"
  type        = map(string)
}

variable "key_vault_id" {
  description = "Key Vault resource ID"
  type        = string
}

variable "aks_private_dns_zone_id" {
  description = "AKS Private Cluster shared DNS Zone ID (control plane needs Private DNS Zone Contributor)"
  type        = string
  default     = ""
}

variable "dns_zone_id" {
  description = "Azure DNS Zone resource ID for cert-manager (empty string = skip)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
