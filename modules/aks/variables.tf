variable "location" {
  description = "Azure region"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD tenant ID (Azure RBAC 통합용)"
  type        = string
}

variable "zones" {
  description = "Availability zones"
  type        = list(string)
}

variable "prefix" {
  description = "Naming prefix"
  type        = string
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version"
  type        = string
}

variable "vm_sizes" {
  description = "VM sizes by pool type"
  type        = map(string)
}

variable "clusters" {
  description = "Cluster definitions"
  type = map(object({
    has_ingress_pool = bool
    vnet_key         = string
    pod_cidr         = string
  }))
}

variable "clusters_with_ingress" {
  description = "Subset of clusters that get an ingress node pool"
  type = map(object({
    has_ingress_pool = bool
    vnet_key         = string
    pod_cidr         = string
  }))
}

variable "rg_cluster" {
  description = "Resource group name per cluster key"
  type        = map(string)
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "subnet_ids" {
  description = "AKS subnet IDs by VNet key"
  type        = map(string)
}

variable "bastion_subnet_id" {
  description = "AzureBastionSubnet ID"
  type        = string
}

variable "jumpbox_subnet_id" {
  description = "Jumpbox subnet ID"
  type        = string
}

variable "control_plane_identity_ids" {
  description = "Control plane managed identity resource IDs by cluster key"
  type        = map(string)
}

variable "kubelet_identity_ids" {
  description = "Kubelet managed identity resource IDs by cluster key"
  type        = map(string)
}

variable "kubelet_client_ids" {
  description = "Kubelet managed identity client IDs by cluster key"
  type        = map(string)
}

variable "kubelet_object_ids" {
  description = "Kubelet managed identity object IDs by cluster key"
  type        = map(string)
}

variable "aks_private_dns_zone_id" {
  description = "Shared Private DNS Zone ID for AKS Private Cluster (cross-VNet API Server resolution)"
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for Container Insights"
  type        = string
}

variable "monitor_workspace_id" {
  description = "Azure Monitor Workspace ID for Managed Prometheus"
  type        = string
}

variable "jumpbox_admin_username" {
  description = "Admin username for the jump VM"
  type        = string
}

variable "jumpbox_ssh_public_key" {
  description = "SSH public key for the jump VM"
  type        = string
}

variable "jumpbox_vm_name" {
  description = "Jump VM name"
  type        = string
}

variable "jumpbox_nic_name" {
  description = "Jump VM NIC name"
  type        = string
}

variable "jumpbox_image_version" {
  description = <<-EOT
    Jump VM Ubuntu 24.04 LTS 이미지 버전 핀.
    재배포 시 예기치 않은 이미지 변경 방지.
    최신 버전 확인:
      az vm image list -p Canonical -f ubuntu-24_04-lts --sku server --all -o table | tail -5
    운영 환경에서는 반드시 특정 버전으로 고정하세요.
  EOT
  type        = string
  default     = "latest"
}

variable "jumpbox_private_ip" {
  description = "Static private IP for Jump VM (must be within jumpbox subnet 10.1.1.0/24)"
  type        = string
  default     = "10.1.1.10"

  validation {
    condition = alltrue([
      can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.jumpbox_private_ip)),
      alltrue([for octet in split(".", var.jumpbox_private_ip) : tonumber(octet) >= 0 && tonumber(octet) <= 255])
    ])
    error_message = "jumpbox_private_ip must be a valid IPv4 address with octets 0-255 (e.g. 10.1.4.10)."
  }
}

variable "bastion_name" {
  description = "Azure Bastion name"
  type        = string
}

variable "bastion_pip_name" {
  description = "Azure Bastion Public IP name"
  type        = string
}

variable "aks_sku_tier" {
  description = "AKS SKU tier (Free or Standard)"
  type        = string
  default     = "Standard"
}

variable "bastion_sku" {
  description = "Azure Bastion SKU (Basic or Standard)"
  type        = string
  default     = "Basic"
}

variable "system_node_count" {
  description = "Number of nodes in the system node pool"
  type        = number
  default     = 3
}

variable "ingress_node_count" {
  description = "Number of nodes in the ingress node pool"
  type        = number
  default     = 3
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}

variable "subscription_id" {
  description = "Azure subscription ID (CustomScript Extension에서 az account set에 사용)"
  type        = string
}

variable "addon_repo_url" {
  description = "Addon 설치 스크립트가 포함된 git 레포 URL (빈 문자열이면 addon 설치 건너뜀)"
  type        = string
  default     = ""
}

variable "addon_repo_branch" {
  description = "Addon 레포 브랜치/태그 (배포 재현성 확보 — HEAD 사용 방지)"
  type        = string
  default     = "main"
}

variable "addon_env" {
  description = "install.sh 실행 전 export할 환경변수 맵 (LETSENCRYPT_EMAIL, GITOPS_REPO_URL 등)"
  type        = map(string)
  default     = {}
}

variable "key_vault_name" {
  description = "Key Vault 이름 — jumpbox MSI가 flux-ssh-private-key 등 시크릿 조회에 사용"
  type        = string
  default     = ""
}

variable "prometheus_query_endpoint" {
  description = "Azure Monitor Workspace Prometheus 쿼리 엔드포인트 — addon_env.PROMETHEUS_URL 미설정 시 자동 주입"
  type        = string
  default     = ""
}
