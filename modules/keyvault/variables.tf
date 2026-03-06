variable "location" {
  description = "Azure region"
  type        = string
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "name" {
  description = "Key Vault name (globally unique)"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD Tenant ID"
  type        = string
}

variable "pe_subnet_id" {
  description = "Private Endpoint 전용 서브넷 ID (ARCHITECTURE.md §5.6)"
  type        = string
}

variable "vnet_ids" {
  description = "VNet IDs — Private DNS Zone을 전체 VNet에 연결 (peered VNet 포함)"
  type        = map(string)
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for Key Vault diagnostic settings"
  type        = string
  default     = null
}

variable "enable_diagnostics" {
  description = "Log Analytics 진단 설정 활성화 여부"
  type        = bool
  default     = true
}

variable "sku_name" {
  description = "Key Vault SKU (standard or premium)"
  type        = string
  default     = "standard"
}

variable "purge_protection" {
  description = "Enable Key Vault purge protection (true for prod)"
  type        = bool
  default     = false
}

variable "allowed_ips" {
  description = <<-EOT
    Key Vault network_acls ip_rules — Terraform 실행 IP를 허용해 private KV에 시크릿 쓰기 가능.
    로컬 실행 시: curl -s ifconfig.me 로 확인한 공인 IP를 CIDR(/32) 형식으로 입력.
    예: ["1.2.3.4/32"]
    CI/CD 실행 시: 파이프라인 에이전트 IP 추가.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
