# ============================================================
# variables.tf — Global unique variables
# ============================================================

variable "acr_name" {
  description = "Azure Container Registry name (globally unique, alphanumeric only, 5-50 chars)"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "ACR name must be 5-50 alphanumeric characters."
  }
}

variable "kv_suffix" {
  description = "Suffix for Key Vault name to ensure global uniqueness (3-8 alphanumeric chars)"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{3,8}$", var.kv_suffix))
    error_message = "Key Vault suffix must be 3-8 alphanumeric characters."
  }
}

variable "jumpbox_admin_username" {
  description = "Admin username for the jump VM"
  type        = string
  default     = "azureadmin"
}

variable "jumpbox_ssh_public_key" {
  description = "SSH public key for the jump VM (path or raw key)"
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure AD Tenant ID"
  type        = string
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "dns_zone_id" {
  description = "Azure DNS Zone resource ID for cert-manager DNS-01 challenge (leave empty to skip DNS-01)"
  type        = string
  default     = ""
}

variable "enable_grafana" {
  description = "Enable Azure Managed Grafana for Prometheus visualization"
  type        = bool
  default     = true
}

variable "enable_sentinel" {
  description = "Enable Microsoft Sentinel on Log Analytics Workspace"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common resource tags applied to all resources"
  type        = map(string)
  default = {
    project     = "azure-k8s-demo"
    environment = "demo"
    managed_by  = "opentofu"
  }
}
