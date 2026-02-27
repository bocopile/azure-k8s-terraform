# ============================================================
# modules/aks/main.tf
# AKS clusters (mgmt/app1/app2) + node pools + Bastion + Jump VM
# ============================================================

# ============================================================
# Resource Groups — one per cluster
# ============================================================

resource "azurerm_resource_group" "cluster" {
  for_each = var.clusters

  name     = var.rg_cluster[each.key]
  location = var.location
  tags     = var.tags
}

# ============================================================
# AKS Clusters (for_each = all clusters)
# ============================================================

resource "azurerm_kubernetes_cluster" "aks" {
  for_each = var.clusters

  name                = "aks-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.cluster[each.key].name
  dns_prefix          = "aks-${each.key}-${var.prefix}"
  kubernetes_version  = var.kubernetes_version

  # AKS Standard Tier — 99.95% Control Plane SLA (ARCHITECTURE.md §4.2)
  sku_tier = "Standard"

  # Private cluster — API Server 공개 엔드포인트 없음 (ADR-021 / C15)
  private_cluster_enabled = true

  # Node OS 자동 업그레이드 (보안 패치)
  node_os_upgrade_channel = "NodeImage"

  # Auto-upgrade: patch 버전 자동 적용
  automatic_upgrade_channel = "patch"

  # Use User-Assigned Identity for control plane
  identity {
    type         = "UserAssigned"
    identity_ids = [var.control_plane_identity_ids[each.key]]
  }

  # Kubelet identity (ACR pull, etc.)
  kubelet_identity {
    user_assigned_identity_id = var.kubelet_identity_ids[each.key]
    client_id                 = var.kubelet_client_ids[each.key]
    object_id                 = var.kubelet_object_ids[each.key]
  }

  # --------------------------------------------------------
  # Default node pool (system pool)
  # 3 nodes, zone-redundant, Regular VM (C6)
  # --------------------------------------------------------
  default_node_pool {
    name       = "system"
    node_count = 3
    vm_size    = var.vm_sizes["system"]
    zones      = var.zones

    vnet_subnet_id = var.subnet_ids[each.value.vnet_key]

    # System critical addons only (C6)
    only_critical_addons_enabled = true

    upgrade_settings {
      max_surge = "33%"
    }

    node_labels = {
      "role"             = "system"
      "kubernetes.io/os" = "linux"
    }
  }

  # --------------------------------------------------------
  # Network Profile — Azure CNI Overlay + Cilium (ADR-005)
  # --------------------------------------------------------
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer" # ADR-016: LB SNAT (NAT GW 미적용)
  }

  # --------------------------------------------------------
  # Container Insights (OMS Agent) — ADR-010
  # --------------------------------------------------------
  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  # --------------------------------------------------------
  # Key Vault CSI Driver (AKS 관리형 애드온) — ADR-004
  # --------------------------------------------------------
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # --------------------------------------------------------
  # Managed Prometheus (Azure Monitor Workspace) — ADR-006
  # --------------------------------------------------------
  monitor_metrics {
    annotations_allowed = null
    labels_allowed      = null
  }

  # --------------------------------------------------------
  # Workload Identity + OIDC (ADR-017, ADR-019)
  # --------------------------------------------------------
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  # --------------------------------------------------------
  # Azure RBAC for Kubernetes + Disable local accounts
  # --------------------------------------------------------
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
  }

  local_account_disabled = true

  # --------------------------------------------------------
  # Node Auto-Provisioning / Karpenter (ADR-007)
  # NAP mode = "Auto": Karpenter가 NodePool CRD로 worker 노드 관리
  # Terraform으로 별도 worker node pool 생성 불필요 (충돌 방지)
  # --------------------------------------------------------
  node_provisioning_profile {
    mode = "Auto"
  }

  # --------------------------------------------------------
  # Azure Policy (Pod Security Admission baseline) — ARCHITECTURE.md §7.1 L2
  # --------------------------------------------------------
  azure_policy_enabled = true

  # --------------------------------------------------------
  # Microsoft Defender for Containers — ARCHITECTURE.md §7.2
  # --------------------------------------------------------
  microsoft_defender {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count,
      kubernetes_version, # auto_upgrade_channel이 관리
    ]
  }
}

# ============================================================
# Ingress Node Pool (Regular VM, mgmt + app1 only)
# 3 nodes, zone-redundant, tainted for Istio Ingress Gateway
# ADR-011 / C6: Regular VM으로 Eviction 방지
# ============================================================

resource "azurerm_kubernetes_cluster_node_pool" "ingress" {
  for_each = var.clusters_with_ingress

  name                  = "ingress"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks[each.key].id
  vm_size               = var.vm_sizes["ingress"]
  node_count            = 3
  zones                 = var.zones
  vnet_subnet_id        = var.subnet_ids[each.value.vnet_key]

  priority        = "Regular"
  eviction_policy = null

  # Taint: Istio Ingress Gateway 전용 (ARCHITECTURE.md §4.2)
  node_taints = ["dedicated=ingress:NoSchedule"]
  node_labels = {
    "role" = "ingress"
  }

  upgrade_settings {
    max_surge = "33%" # system pool과 통일
  }

  tags = var.tags
}

# ============================================================
# Worker Node Pool — NAP(Karpenter) 사용 시 주석 처리
#
# NAP mode = "Auto"가 활성화된 클러스터에서는 Karpenter가
# NodePool CRD를 통해 worker 노드를 직접 프로비저닝합니다.
# Terraform으로 user node pool을 별도 생성하면 NAP와 충돌합니다.
#
# Worker 노드 설정은 addons/scripts/08-karpenter-nodepool.sh 참조
# ============================================================
#
# resource "azurerm_kubernetes_cluster_node_pool" "worker" {
#   for_each              = var.clusters
#   name                  = "worker"
#   kubernetes_cluster_id = azurerm_kubernetes_cluster.aks[each.key].id
#   vm_size               = "Standard_D2s_v5"
#   node_count            = 0
#   priority              = "Spot"
#   eviction_policy       = "Delete"
#   spot_max_price        = -1
#   zones                 = var.zones
#   vnet_subnet_id        = var.subnet_ids[each.value.vnet_key]
#   node_labels = {
#     "role"                                  = "worker"
#     "kubernetes.azure.com/scalesetpriority" = "spot"
#   }
#   node_taints = ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]
#   lifecycle { ignore_changes = [node_count] }
# }

# ============================================================
# Azure Bastion (Basic SKU — mgmt cluster RG, ADR-021)
# ============================================================

resource "azurerm_public_ip" "bastion" {
  name                = var.bastion_pip_name
  location            = var.location
  resource_group_name = azurerm_resource_group.cluster["mgmt"].name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
  tags                = var.tags
}

resource "azurerm_bastion_host" "bastion" {
  name                = var.bastion_name
  location            = var.location
  resource_group_name = azurerm_resource_group.cluster["mgmt"].name
  sku                 = "Basic"
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig-bastion"
    subnet_id            = var.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# ============================================================
# Jump VM (Standard_B2s, Linux, mgmt cluster RG, ADR-021)
# Private IP only — Bastion 경유 전용
# ============================================================

resource "azurerm_network_interface" "jumpbox" {
  name                = var.jumpbox_nic_name
  location            = var.location
  resource_group_name = azurerm_resource_group.cluster["mgmt"].name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-jumpbox"
    subnet_id                     = var.jumpbox_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.jumpbox_private_ip
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                = var.jumpbox_vm_name
  location            = var.location
  resource_group_name = azurerm_resource_group.cluster["mgmt"].name
  size                = var.vm_sizes["jumpbox"]
  admin_username      = var.jumpbox_admin_username

  network_interface_ids = [azurerm_network_interface.jumpbox.id]

  admin_ssh_key {
    username   = var.jumpbox_admin_username
    public_key = var.jumpbox_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Jump VM 초기화: kubectl, az cli, helm, kubelogin, k9s, kubent, istioctl
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # Azure CLI
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash

    # kubectl + kubelogin
    az aks install-cli --install-location /usr/local/bin/kubectl \
      --kubelogin-install-location /usr/local/bin/kubelogin || true

    # Helm 3
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # k9s (터미널 K8s UI)
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    curl -fsSL "https://github.com/derailed/k9s/releases/download/$${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin k9s

    # kubent (deprecated API 탐지)
    curl -fsSL https://github.com/doitintl/kube-no-trouble/releases/latest/download/kubent-linux-amd64.tar.gz \
      | tar -xz -C /usr/local/bin

    # istioctl
    curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=1.28.0 TARGET_ARCH=x86_64 sh -
    mv istio-*/bin/istioctl /usr/local/bin/istioctl
    rm -rf istio-*

    # ~/.bashrc 편의 설정 (azureadmin 사용자)
    cat >> /home/azureadmin/.bashrc <<'BASHRC'
# AKS kubeconfig 자동 설정 aliases
alias kc-mgmt='az aks get-credentials -g rg-k8s-demo-mgmt -n aks-mgmt --overwrite-existing'
alias kc-app1='az aks get-credentials -g rg-k8s-demo-app1 -n aks-app1 --overwrite-existing'
alias kc-app2='az aks get-credentials -g rg-k8s-demo-app2 -n aks-app2 --overwrite-existing'
alias kc-all='kc-mgmt && kc-app1 && kc-app2'
export KUBECONFIG=$HOME/.kube/config
BASHRC

    echo "Jump VM init complete" > /tmp/jumpvm-init.done
  EOF
  )

  tags = var.tags
}
