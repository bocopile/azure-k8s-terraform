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
  description = "SSH public key string for the jump VM (e.g. output of: cat ~/.ssh/id_rsa.pub)"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD Tenant ID"
  type        = string
  sensitive   = true
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
  sensitive   = true
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

# ============================================================
# 환경 기본
# ============================================================

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "koreacentral"
}

variable "prefix" {
  description = "Naming prefix for all resources"
  type        = string
  default     = "k8s-demo"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version"
  type        = string
  default     = "1.34"
}

# ============================================================
# VM sizes
# ============================================================

variable "vm_size_system" {
  description = "VM size for AKS system node pool"
  type        = string
  default     = "Standard_D2s_v5"
}

variable "vm_size_ingress" {
  description = "VM size for AKS ingress node pool"
  type        = string
  default     = "Standard_D2s_v5"
}

variable "vm_size_jumpbox" {
  description = "VM size for Jump VM"
  type        = string
  default     = "Standard_B2s"
}

# ============================================================
# SKU / Tier
# ============================================================

variable "aks_sku_tier" {
  description = "AKS SKU tier (Free or Standard)"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard"], var.aks_sku_tier)
    error_message = "aks_sku_tier must be Free or Standard."
  }
}

variable "acr_sku" {
  description = "Azure Container Registry SKU (Basic, Standard, or Premium)"
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be Basic, Standard, or Premium."
  }
}

variable "bastion_sku" {
  description = "Azure Bastion SKU (Basic or Standard)"
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard"], var.bastion_sku)
    error_message = "bastion_sku must be Basic or Standard."
  }
}

variable "keyvault_sku" {
  description = "Key Vault SKU (standard or premium)"
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "premium"], var.keyvault_sku)
    error_message = "keyvault_sku must be standard or premium."
  }
}

# ============================================================
# 보존기간 / 정책
# ============================================================

variable "log_retention_days" {
  description = "Log Analytics Workspace retention in days"
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "flow_log_retention_days" {
  description = "NSG Flow Log retention in days"
  type        = number
  default     = 30

  validation {
    condition     = var.flow_log_retention_days >= 1 && var.flow_log_retention_days <= 365
    error_message = "flow_log_retention_days must be between 1 and 365."
  }
}

variable "backup_retention_duration" {
  description = "AKS backup retention duration (ISO 8601, e.g. P7D)"
  type        = string
  default     = "P7D"
}

# ============================================================
# 보안
# ============================================================

variable "keyvault_purge_protection" {
  description = "Enable Key Vault purge protection (demo 환경에서는 false로 override)"
  type        = bool
  default     = true
}

variable "grafana_public_access" {
  description = "Enable public network access for Azure Managed Grafana (프라이빗 환경에서는 false 권장)"
  type        = bool
  default     = false
}

variable "grafana_sku" {
  description = "Azure Managed Grafana SKU (Standard or Essential)"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Essential"], var.grafana_sku)
    error_message = "grafana_sku must be Standard or Essential."
  }
}

variable "backup_soft_delete" {
  description = "Enable soft delete on Backup Vault. false = 즉시 삭제 (demo/dev), true = 보존 (prod)"
  type        = bool
  default     = false
}
