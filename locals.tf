# ============================================================
# locals.tf — Shared local values
# ============================================================

locals {
  # --- Region & Availability Zones ---
  location = var.location
  zones    = ["1", "2", "3"]

  # --- Naming prefix ---
  prefix = var.prefix

  # --- Kubernetes version ---
  kubernetes_version = var.kubernetes_version

  # --- VM sizes ---
  vm_sizes = {
    system  = var.vm_size_system
    ingress = var.vm_size_ingress
    jumpbox = var.vm_size_jumpbox
    # worker 사이즈는 Karpenter/NAP NodePool CRD에서 직접 관리 (ARCHITECTURE.md §4.3)
  }

  # --- Cluster definitions ---
  # pod_cidr: Azure CNI Overlay — 클러스터간 비중복 Pod CIDR (ARCHITECTURE.md §3.2)
  clusters = {
    mgmt = {
      has_ingress_pool = true
      vnet_key         = "mgmt"
      pod_cidr         = "10.244.0.0/16"
    }
    app1 = {
      has_ingress_pool = true
      vnet_key         = "app1"
      pod_cidr         = "10.245.0.0/16"
    }
    app2 = {
      has_ingress_pool = false
      vnet_key         = "app2"
      pod_cidr         = "10.246.0.0/16"
    }
  }

  # Clusters that get an ingress node pool (mgmt + app1, ARCHITECTURE.md §4.2)
  clusters_with_ingress = {
    for k, v in local.clusters : k => v if v.has_ingress_pool
  }

  # --- VNet definitions ---
  vnets = {
    mgmt = { cidr = "10.1.0.0/16" }
    app1 = { cidr = "10.2.0.0/16" }
    app2 = { cidr = "10.3.0.0/16" }
  }

  # --- Subnet CIDRs ---
  # AKS subnet per VNet (nodes only — CNI Overlay: 노드 IP만 필요)
  aks_subnets = {
    mgmt = "10.1.0.0/22"
    app1 = "10.2.0.0/22"
    app2 = "10.3.0.0/22"
  }

  # Bastion + jumpbox (mgmt VNet only, ARCHITECTURE.md §5.7)
  # AKS subnet = 10.1.0.0/22 (10.1.0.0 ~ 10.1.3.255) 이후 대역 사용
  bastion_subnet_cidr = "10.1.100.0/26" # Azure 요구사항: /26 이상
  jumpbox_subnet_cidr = "10.1.4.0/24"

  # Private Endpoint 전용 서브넷 (mgmt VNet, ARCHITECTURE.md §5.6)
  pe_subnet_cidr = "10.1.5.0/24"

  # Jump VM 고정 Private IP (Static 할당)
  jumpbox_private_ip = "10.1.4.10"

  # --- Resource group names ---
  rg_common = "rg-${local.prefix}-common"
  rg_cluster = {
    for k in keys(local.clusters) : k => "rg-${local.prefix}-${k}"
  }

  # --- Resource naming ---
  names = {
    acr               = var.acr_name
    key_vault         = "kv-${local.prefix}-${var.kv_suffix}"
    log_analytics     = "law-${local.prefix}"
    monitor_workspace = "mon-${local.prefix}"
    app_insights      = "appi-${local.prefix}"
    backup_vault      = "bv-${local.prefix}"
    backup_policy     = "bp-aks-daily"
    bastion           = "bastion-${local.prefix}"
    bastion_pip       = "pip-bastion-${local.prefix}" # Bastion 전용 Public IP
    jumpbox_vm        = "vm-jumpbox"
    jumpbox_nic       = "nic-jumpbox"
    grafana           = "grafana-${local.prefix}"
    flow_log_storage  = "st${replace(local.prefix, "-", "")}${lower(var.kv_suffix)}fl" # globally unique: kv_suffix 재활용, 3-24 chars lowercase alphanumeric
    backup_storage    = "st${replace(local.prefix, "-", "")}${lower(var.kv_suffix)}bk" # AKS Backup Extension 스테이징 스토리지
    # jumpbox는 Public IP 없음 — Bastion 경유 전용 (ARCHITECTURE.md §5.7, ADR-021)
    # Data Services (P5) — kv_suffix 재활용으로 전역 고유성 확보
    redis      = "cache-${local.prefix}-${var.kv_suffix}"
    mysql      = "mysql-${local.prefix}-${var.kv_suffix}"
    servicebus = "sb-${local.prefix}-${var.kv_suffix}"
  }
}
