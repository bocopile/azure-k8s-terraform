# ============================================================
# modules/data-services/variables.tf
# ============================================================

variable "location" {
  description = "Azure region"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "pe_subnet_id" {
  description = "Private Endpoint subnet ID (snet-private-endpoints)"
  type        = string
}

variable "vnet_ids" {
  description = "VNet IDs by key (mgmt/app1/app2) — Private DNS Zone VNet link용"
  type        = map(string)
}

variable "key_vault_id" {
  description = "Key Vault ID — Connection String Secret 저장"
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID — Diagnostic Settings"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}

# ============================================================
# Enable flags
# ============================================================

variable "enable_redis" {
  type    = bool
  default = false
}

variable "enable_mysql" {
  type    = bool
  default = false
}

variable "enable_servicebus" {
  type    = bool
  default = false
}

# ============================================================
# Redis
# ============================================================

variable "redis_name" {
  description = "Azure Cache for Redis 이름 (전역 고유)"
  type        = string
}

variable "redis_capacity" {
  description = "Redis Premium Capacity (1=6GB / 2=13GB / 3=26GB)"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 3], var.redis_capacity)
    error_message = "redis_capacity must be 1, 2, or 3 (Premium SKU 제한)."
  }
}

# ============================================================
# MySQL
# ============================================================

variable "mysql_name" {
  description = "MySQL Flexible Server 이름 (전역 고유)"
  type        = string
}

variable "mysql_admin_username" {
  description = "MySQL 관리자 계정명"
  type        = string
  default     = "mysqladmin"
}

variable "mysql_sku_name" {
  description = "MySQL SKU (B_Standard_B2ms=dev / GP_Standard_D4ds_v4=prod)"
  type        = string
  default     = "B_Standard_B2ms"

  validation {
    condition     = can(regex("^(B|GP|MO)_Standard_", var.mysql_sku_name))
    error_message = "mysql_sku_name must start with B_Standard_, GP_Standard_, or MO_Standard_ (예: B_Standard_B2ms, GP_Standard_D4ds_v4)."
  }
}

variable "mysql_version" {
  description = "MySQL 버전 (8.0.21 / 8.0.40)"
  type        = string
  default     = "8.0.21"

  validation {
    condition     = can(regex("^8\\.0\\.", var.mysql_version))
    error_message = "mysql_version must be 8.0.x (예: 8.0.21, 8.0.40)."
  }
}

variable "mysql_storage_gb" {
  description = "MySQL 스토리지 크기 (GB, 20–16384)"
  type        = number
  default     = 20

  validation {
    condition     = var.mysql_storage_gb >= 20 && var.mysql_storage_gb <= 16384
    error_message = "mysql_storage_gb must be between 20 and 16384."
  }
}

variable "mysql_databases" {
  description = "초기 생성할 데이터베이스 이름 목록"
  type        = list(string)
  default     = []
}

# ============================================================
# Service Bus
# ============================================================

variable "servicebus_name" {
  description = "Service Bus Namespace 이름 (전역 고유)"
  type        = string
}

variable "servicebus_capacity" {
  description = "Service Bus Premium Capacity Units (1/2/4/8)"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 4, 8], var.servicebus_capacity)
    error_message = "servicebus_capacity must be 1, 2, 4, or 8 (Premium SKU 제한)."
  }
}

variable "servicebus_queues" {
  description = "생성할 Queue 이름 목록"
  type        = list(string)
  default     = []
}

variable "servicebus_topics" {
  description = "생성할 Topic 이름 목록"
  type        = list(string)
  default     = []
}
