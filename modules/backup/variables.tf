variable "location" {
  description = "Azure region"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "vault_name" {
  description = "Backup Vault name"
  type        = string
}

variable "policy_name" {
  description = "Backup Policy name"
  type        = string
}

variable "enable_soft_delete" {
  description = "Enable soft delete on Backup Vault. false = 즉시 삭제 (demo/dev), true = 보존 (prod)"
  type        = bool
  default     = false
}

variable "backup_retention_duration" {
  description = "AKS backup retention duration (ISO 8601, e.g. P7D)"
  type        = string
  default     = "P7D"
}

variable "backup_storage_account_name" {
  description = "Storage Account name for AKS Backup Extension blob staging (globally unique, lowercase alphanumeric)"
  type        = string
}

variable "subscription_id" {
  description = "Azure Subscription ID (AKS Backup Extension configuration)"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID (AKS Backup Extension credentials)"
  type        = string
}

variable "cluster_ids" {
  description = "AKS cluster resource IDs by cluster key"
  type        = map(string)
}

variable "cluster_rg_names" {
  description = "AKS cluster resource group names by cluster key (snapshot destination)"
  type        = map(string)
}

variable "cluster_rg_ids" {
  description = "AKS cluster resource group resource IDs by cluster key (RBAC scope)"
  type        = map(string)
}

variable "kubelet_object_ids" {
  description = "Kubelet managed identity object IDs by cluster key (RBAC for disk snapshots)"
  type        = map(string)
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
