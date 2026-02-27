variable "location" {
  type = string
}

variable "rg_common" {
  type = string
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

variable "tags" {
  type    = map(string)
  default = {}
}
