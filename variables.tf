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

variable "enable_mcas" {
  description = "Enable Sentinel MCAS Data Connector (Microsoft 365 E5 / EMS E5 라이선스 필요, enable_sentinel = true 전제)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common resource tags applied to all resources"
  type        = map(string)
  default = {
    project     = "azure-k8s"
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
  default     = "k8s"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version"
  type        = string
  default     = "1.35"
}

# ============================================================
# VM sizes
# ============================================================

variable "vm_size_system" {
  description = "VM size for AKS system node pool"
  type        = string
  default     = "Standard_D2s_v4"
}

variable "vm_size_ingress" {
  description = "VM size for AKS ingress node pool"
  type        = string
  default     = "Standard_D2s_v4"
}

variable "system_node_count" {
  description = "Number of nodes in the AKS system node pool (per cluster)"
  type        = number
  default     = 3

  validation {
    condition     = var.system_node_count >= 1 && var.system_node_count <= 10
    error_message = "system_node_count must be between 1 and 10."
  }
}

variable "ingress_node_count" {
  description = "Number of nodes in the AKS ingress node pool (mgmt + app1 only)"
  type        = number
  default     = 3

  validation {
    condition     = var.ingress_node_count >= 1 && var.ingress_node_count <= 10
    error_message = "ingress_node_count must be between 1 and 10."
  }
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

variable "acr_enable_private_endpoint" {
  description = "ACR Private Endpoint 활성화 (Standard/Premium SKU 필요 — Basic은 미지원)"
  type        = bool
  default     = false

  validation {
    condition     = !(var.acr_enable_private_endpoint && var.acr_sku == "Basic")
    error_message = "acr_enable_private_endpoint = true 는 Basic SKU를 지원하지 않습니다. acr_sku를 Standard 또는 Premium으로 변경하세요."
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
  default     = false
}

variable "kv_allowed_ips" {
  description = <<-EOT
    Key Vault 접근 허용 IP 목록 (CIDR /32 형식).
    Terraform을 로컬에서 실행할 때 data_services secrets 쓰기를 위해 반드시 설정.
    설정 방법 (terraform.tfvars):
      kv_allowed_ips = ["$(curl -s ifconfig.me)/32"]
    또는:
      kv_allowed_ips = ["1.2.3.4/32"]
    CI/CD 실행 시 파이프라인 에이전트 공인 IP 추가.
  EOT
  type        = list(string)
  default     = []
}

variable "grafana_public_access" {
  description = "Enable public network access for Azure Managed Grafana. Demo: true / Prod: false (PE 추가 필요)"
  type        = bool
  default     = true
}

variable "grafana_admin_object_ids" {
  description = "Grafana Admin 역할을 부여할 추가 사용자 Object ID 목록 (배포 주체는 자동 부여됨)"
  type        = list(string)
  default     = []
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

variable "addon_repo_url" {
  description = "Addon 설치 스크립트가 포함된 git 레포 URL (빈 문자열이면 CustomScript Extension에서 addon 설치 건너뜀)"
  type        = string
  default     = ""
}

variable "addon_repo_branch" {
  description = "Addon 레포 브랜치/태그 — 배포 재현성 확보 (예: main, v1.2.0)"
  type        = string
  default     = "main"
}

variable "jumpbox_image_version" {
  description = <<-EOT
    Jump VM Ubuntu 24.04 LTS 이미지 버전. 운영 환경에서는 특정 버전으로 고정 권장.
    최신 버전 확인:
      az vm image list -p Canonical -f ubuntu-24_04-lts --sku server --all -o table | tail -5
    예시: "24.04.202501140"
  EOT
  type        = string
  default     = "latest"
}

# ============================================================
# Addon 환경변수 — install.sh에 주입 (tofu apply 한 번으로 전체 배포)
# ============================================================

variable "addon_env" {
  description = <<-EOT
    install.sh 실행 전 export할 환경변수 맵.
    예시 (terraform.tfvars):
      addon_env = {
        LETSENCRYPT_EMAIL       = "admin@example.com"
        GITOPS_REPO_URL         = "ssh://git@github.com/org/repo.git"
        GITOPS_BRANCH           = "main"
        GITOPS_PATH             = "clusters"
        AZURE_SUBSCRIPTION_ID   = "<subscription-id>"
        AZURE_TENANT_ID         = "<tenant-id>"
        DNS_ZONE_NAME           = "example.com"
        DNS_ZONE_RG             = "rg-dns"
        CERT_MANAGER_CLIENT_ID  = "<cert-manager-mi-client-id>"
        PROMETHEUS_URL          = ""
        GRAFANA_URL             = ""
        GRAFANA_ENABLED         = "false"
      }
  EOT
  type        = map(string)
  default     = {}
}

variable "flux_ssh_private_key" {
  description = <<-EOT
    Flux GitOps용 SSH Deploy Key (private key 전체 내용).
    Key Vault에 'flux-ssh-private-key' 시크릿으로 저장됩니다.
    jumpbox CustomScript Extension에서 MSI로 조회 후 파일로 기록.
    생성: ssh-keygen -t ed25519 -C flux-deploy -f ~/.ssh/flux-deploy-key -N ''
    공개키(flux-deploy-key.pub)를 GitHub/GitLab Deploy Key로 등록하세요.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

# ============================================================
# Data Services (P5)
# ============================================================

variable "enable_redis" {
  description = "Azure Cache for Redis (Premium) 배포 여부"
  type        = bool
  default     = false
}

variable "enable_mysql" {
  description = "Azure Database for MySQL Flexible Server 배포 여부"
  type        = bool
  default     = false
}

variable "enable_servicebus" {
  description = "Azure Service Bus (Premium) 배포 여부 — RabbitMQ AMQP 호환"
  type        = bool
  default     = false
}

variable "redis_capacity" {
  description = "Redis Premium Capacity (1=6GB / 2=13GB / 3=26GB)"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 3], var.redis_capacity)
    error_message = "redis_capacity must be 1, 2, or 3."
  }
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
}

variable "mysql_databases" {
  description = "초기 생성할 MySQL 데이터베이스 이름 목록"
  type        = list(string)
  default     = []
}

variable "servicebus_capacity" {
  description = "Service Bus Premium Capacity Units (1/2/4/8)"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 4, 8], var.servicebus_capacity)
    error_message = "servicebus_capacity must be 1, 2, 4, or 8."
  }
}

variable "servicebus_queues" {
  description = "생성할 Service Bus Queue 이름 목록"
  type        = list(string)
  default     = []
}

variable "servicebus_topics" {
  description = "생성할 Service Bus Topic 이름 목록"
  type        = list(string)
  default     = []
}
