variable "location" {
  description = "Azure region"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "account_name" {
  description = "Cosmos DB account name (globally unique)"
  type        = string
}

variable "database_name" {
  description = "Cosmos DB database name"
  type        = string
  default     = "vectordb"
}

variable "container_name" {
  description = "Cosmos DB container name for vector embeddings"
  type        = string
  default     = "embeddings"
}

variable "pe_subnet_id" {
  description = "Private Endpoint subnet ID"
  type        = string
}

variable "vnet_ids" {
  description = "VNet IDs for Private DNS Zone links"
  type        = map(string)
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
