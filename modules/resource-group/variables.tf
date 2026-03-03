variable "location" {
  description = "Azure region"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name (shared infra)"
  type        = string
}

variable "rg_cluster" {
  description = "Cluster resource group names by key (e.g. mgmt, app1, app2)"
  type        = map(string)
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
