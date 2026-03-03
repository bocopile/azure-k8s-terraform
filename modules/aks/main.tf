# ============================================================
# modules/aks/main.tf
# AKS clusters (mgmt/app1/app2) + node pools + Bastion + Jump VM
# ============================================================

# ============================================================
# AKS Clusters (for_each = all clusters)
# ============================================================

resource "azurerm_kubernetes_cluster" "aks" {
  for_each = var.clusters

  name                = "aks-${each.key}"
  location            = var.location
  resource_group_name = var.rg_cluster[each.key]
  dns_prefix          = "aks-${each.key}-${var.prefix}"
  kubernetes_version  = var.kubernetes_version

  # AKS SKU Tier — Standard = 99.95% Control Plane SLA (ARCHITECTURE.md §4.2)
  sku_tier = var.aks_sku_tier

  # Private cluster — API Server 공개 엔드포인트 없음 (ADR-021 / C15)
  private_cluster_enabled = true
  private_dns_zone_id     = var.aks_private_dns_zone_id

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
    node_count = var.system_node_count
    vm_size    = var.vm_sizes["system"]
    zones      = var.zones

    vnet_subnet_id = var.subnet_ids[each.value.vnet_key]

    # System critical addons only (C6)
    # azurerm v4.x: only_critical_addons_enabled deprecated → node_taints 사용
    node_taints = ["CriticalAddonsOnly=true:NoSchedule"]

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
    pod_cidr            = "10.${each.key == "mgmt" ? 244 : each.key == "app1" ? 245 : 246}.0.0/16"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer" # ADR-016: LB SNAT → TODO: NAT Gateway 도입 검토 (SNAT 포트 고갈 방지)
  }

  # --------------------------------------------------------
  # Container Insights (OMS Agent) — ADR-010
  # TODO: OMS Agent deprecated → Azure Monitor Agent(AMA) + DCR 기반 전환 검토
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
  # azurerm v4.x: azure_active_directory_role_based_access_control deprecated
  # --------------------------------------------------------
  role_based_access_control_enabled = true
  local_account_disabled            = true

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
  node_count            = var.ingress_node_count
  zones                 = var.zones
  vnet_subnet_id        = var.subnet_ids[each.value.vnet_key]

  priority = "Regular"

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
  resource_group_name = lookup(var.rg_cluster, "mgmt", values(var.rg_cluster)[0])
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
  tags                = var.tags
}

resource "azurerm_bastion_host" "bastion" {
  name                = var.bastion_name
  location            = var.location
  resource_group_name = lookup(var.rg_cluster, "mgmt", values(var.rg_cluster)[0])
  sku                 = var.bastion_sku
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig-bastion"
    subnet_id            = var.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# ============================================================
# Jump VM (Linux, mgmt cluster RG, ADR-021)
# Private IP only — Bastion 경유 전용
# ============================================================

resource "azurerm_network_interface" "jumpbox" {
  name                = var.jumpbox_nic_name
  location            = var.location
  resource_group_name = lookup(var.rg_cluster, "mgmt", values(var.rg_cluster)[0])
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
  resource_group_name = lookup(var.rg_cluster, "mgmt", values(var.rg_cluster)[0])
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
    version   = "22.04.202502110" # pinned for reproducibility (update periodically)
  }

  # Jump VM 초기화: kubectl, az cli, helm, kubelogin, k9s, kubent, istioctl
  # NOTE: pinned versions for reproducibility. Update periodically.
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # Azure CLI (Microsoft signed package)
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash

    # kubectl + kubelogin (via az cli — uses Microsoft CDN)
    az aks install-cli --install-location /usr/local/bin/kubectl \
      --kubelogin-install-location /usr/local/bin/kubelogin || true

    # Helm 3 (pinned version)
    HELM_VERSION="v3.17.3"
    curl -fsSL "https://get.helm.sh/helm-$${HELM_VERSION}-linux-amd64.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin linux-amd64/helm

    # k9s (pinned version)
    K9S_VERSION="v0.50.6"
    curl -fsSL "https://github.com/derailed/k9s/releases/download/$${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin k9s

    # kubent (pinned version)
    KUBENT_VERSION="0.7.3"
    curl -fsSL "https://github.com/doitintl/kube-no-trouble/releases/download/$${KUBENT_VERSION}/kubent-$${KUBENT_VERSION}-linux-amd64.tar.gz" \
      | tar -xz -C /usr/local/bin

    # istioctl (pinned version)
    ISTIO_VERSION="1.28.0"
    curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=$${ISTIO_VERSION} TARGET_ARCH=x86_64 sh -
    mv istio-*/bin/istioctl /usr/local/bin/istioctl
    rm -rf istio-*

    # ~/.bashrc 편의 설정 (var.clusters 기반 동적 생성)
    cat >> /home/${var.jumpbox_admin_username}/.bashrc <<'BASHRC'
# AKS kubeconfig aliases (auto-generated)
%{for name, _ in var.clusters~}
alias kc-${name}='az aks get-credentials -g ${var.rg_cluster[name]} -n aks-${name} --overwrite-existing'
%{endfor~}
alias kc-all='${join(" && ", [for name, _ in var.clusters : "kc-${name}"])}'
export KUBECONFIG=$HOME/.kube/config
BASHRC

    echo "Jump VM init complete" > /tmp/jumpvm-init.done
  EOF
  )

  tags = var.tags
}
