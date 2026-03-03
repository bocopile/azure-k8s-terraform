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

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
