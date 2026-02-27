variable "location" {
  type = string
}

variable "rg_common" {
  type = string
}

variable "log_analytics_name" {
  type = string
}

variable "monitor_workspace_name" {
  type = string
}

variable "app_insights_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
