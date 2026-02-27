variable "location" {
  type = string
}

variable "rg_common" {
  type = string
}

variable "name" {
  description = "ACR name (globally unique, alphanumeric)"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
