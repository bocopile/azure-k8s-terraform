# ============================================================
# locals.tf — Shared local values
# ============================================================

locals {
  # --- Region & Availability Zones ---
  location = "koreacentral"
  zones    = ["1", "2", "3"]

  # --- Naming prefix ---
  prefix = "k8s-demo"

  # --- Kubernetes version (ARCHITECTURE.md v3.2.0 기준: AKS v1.34) ---
  kubernetes_version = "1.34"

  # --- VM sizes ---
  vm_sizes = {
    system  = "Standard_D2s_v5"
    ingress = "Standard_D2s_v5"
    jumpbox = "Standard_B2s"
    # worker 사이즈는 Karpenter/NAP NodePool CRD에서 직접 관리 (ARCHITECTURE.md §4.3)
  }

  # --- Cluster definitions ---
  clusters = {
    mgmt = {
      has_ingress_pool = true
      vnet_key         = "mgmt"
    }
    app1 = {
      has_ingress_pool = true
      vnet_key         = "app1"
    }
    app2 = {
      has_ingress_pool = false
      vnet_key         = "app2"
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
  bastion_subnet_cidr = "10.1.100.0/26" # Azure 요구사항: /26 이상
  jumpbox_subnet_cidr = "10.1.1.0/24"

  # Private Endpoint 전용 서브넷 (mgmt VNet, ARCHITECTURE.md §5.6)
  pe_subnet_cidr = "10.1.2.0/24"

  # Jump VM 고정 Private IP (Static 할당)
  jumpbox_private_ip = "10.1.1.10"

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
    bastion_pip       = "pip-bastion" # Bastion 전용 Public IP
    jumpbox_vm        = "vm-jumpbox"
    jumpbox_nic       = "nic-jumpbox"
    grafana           = "grafana-${local.prefix}"
    flow_log_storage  = "stk8sdemoflowlogs" # 3-24 chars, lowercase alphanumeric only
    # jumpbox는 Public IP 없음 — Bastion 경유 전용 (ARCHITECTURE.md §5.7, ADR-021)
  }
}
