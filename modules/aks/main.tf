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
    only_critical_addons_enabled = true

    os_sku = "AzureLinux"

    upgrade_settings {
      max_surge = "33%"
    }

    node_labels = {
      "role" = "system"
    }
  }

  # --------------------------------------------------------
  # Network Profile — Azure CNI Overlay + Cilium (ADR-005)
  # --------------------------------------------------------
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    pod_cidr            = each.value.pod_cidr
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
  # Azure AD 통합 + Azure RBAC 기반 K8s 인가
  # --------------------------------------------------------
  role_based_access_control_enabled = true
  local_account_disabled            = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenant_id
  }

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
# Ingress Node Pool (mgmt + app1 only)
# zone-redundant, tainted for Istio Ingress Gateway
# ingress_spot_enabled = true 시 Spot 인스턴스 (~80% 비용 절감)
# Spot 사용 시 lowPriorityCores 쿼터 필요:
#   az quota show --scope /subscriptions/<SUB>/providers/Microsoft.Compute/locations/koreacentral \
#     --resource-name lowPriorityCores
# ============================================================

resource "azurerm_kubernetes_cluster_node_pool" "ingress" {
  for_each = var.clusters_with_ingress

  name                  = "ingress"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks[each.key].id
  vm_size               = var.vm_sizes["ingress"]
  node_count            = var.ingress_node_count
  zones                 = var.zones
  vnet_subnet_id        = var.subnet_ids[each.value.vnet_key]

  priority        = var.ingress_spot_enabled ? "Spot" : "Regular"
  eviction_policy = var.ingress_spot_enabled ? "Delete" : null
  spot_max_price  = var.ingress_spot_enabled ? -1 : null
  os_sku          = "AzureLinux"

  # Taint: Istio Ingress Gateway 전용 (ARCHITECTURE.md §4.2)
  node_taints = [
    "dedicated=ingress:NoSchedule",
  ]
  node_labels = {
    "role" = "ingress"
  }

  upgrade_settings {
    max_surge                     = "1"
    drain_timeout_in_minutes      = 30
    node_soak_duration_in_minutes = 0
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

# ============================================================
# P2: Jump VM User-Assigned Managed Identity
# System-Assigned 대신 UAMI 사용 — principal_id가 apply 전에 known되어
# 동일 apply에서 role assignment 생성 가능 (System-Assigned는 plan-time 참조 불가)
# ============================================================

resource "azurerm_user_assigned_identity" "jumpbox_mi" {
  name                = "mi-jumpbox"
  location            = var.location
  resource_group_name = lookup(var.rg_cluster, "mgmt", values(var.rg_cluster)[0])
  tags                = var.tags
}

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

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.jumpbox_mi.id]
  }

  admin_ssh_key {
    username   = var.jumpbox_admin_username
    public_key = var.jumpbox_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  # Ubuntu 24.04 LTS (Canonical 기본 이미지 — Marketplace 약관 동의 불필요, plan 블록 없음)
  # version: 운영 환경에서는 jumpbox_image_version 변수로 특정 버전 고정 권장
  #   최신 버전 확인: az vm image list -p Canonical -f ubuntu-24_04-lts --sku server --all -o table | tail -5
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = var.jumpbox_image_version
  }

  # Jump VM 초기화: az CLI + kubectl + addon 설치까지 cloud-init에서 통합
  # NOTE: pinned versions for reproducibility. Update periodically.
  # <<-EOF 로 heredoc 작성 시 closing EOF의 들여쓰기 기준으로 앞 공백이 제거됨.
  # closing EOF를 content와 동일한 4칸으로 맞춤 → shebang이 position 0에 위치
  # ── cloud-init 역할 ───────────────────────────────────────────
  # az CLI를 병렬 설치에 통합 + MSI 인증/kubeconfig/addon 설치까지 처리
  # CustomScript Extension 제거로 tofu apply 시간 단축
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    LOG=/var/log/jumpvm-init.log
    exec >> "$LOG" 2>&1
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] cloud-init 시작"

    # Ubuntu 초기 부팅 시 unattended-upgrades가 apt lock을 선점하는 경우 대기
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] apt lock 해제 대기 중..."
    while systemctl is-active --quiet apt-daily.service \
          apt-daily-upgrade.service 2>/dev/null; do
      sleep 10
    done

    # 기본 패키지 (az CLI apt 레포 설정에 필요한 패키지 포함)
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      curl ca-certificates git apt-transport-https gnupg lsb-release

    # ── 바이너리 도구 병렬 설치 (az CLI 포함) ─────────────────────
    install_azure_cli() {
      mkdir -p /etc/apt/keyrings
      curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] \
        https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/azure-cli.list
      apt-get update -qq
      apt-get install -y --no-install-recommends azure-cli
      echo "[$(date '+%Y-%m-%dT%H:%M:%S')] az CLI 설치 완료"
    }

    install_helm() {
      HELM_VERSION="v3.20.0"
      HELM_TAR="helm-$${HELM_VERSION}-linux-amd64.tar.gz"
      curl -fsSL "https://get.helm.sh/$${HELM_TAR}" -o "/tmp/$${HELM_TAR}"
      HELM_SHA256=$(curl -fsSL "https://get.helm.sh/$${HELM_TAR}.sha256sum" | awk '{print $1}')
      echo "$${HELM_SHA256}  /tmp/$${HELM_TAR}" | sha256sum -c -
      tar -xz --strip-components=1 -C /usr/local/bin linux-amd64/helm -f "/tmp/$${HELM_TAR}"
      rm -f "/tmp/$${HELM_TAR}"
    }

    install_k9s() {
      K9S_VERSION="v0.50.18"
      K9S_TAR="k9s_Linux_amd64.tar.gz"
      curl -fsSL "https://github.com/derailed/k9s/releases/download/$${K9S_VERSION}/$${K9S_TAR}" \
        -o "/tmp/$${K9S_TAR}"
      K9S_SHA256=$(curl -fsSL "https://github.com/derailed/k9s/releases/download/$${K9S_VERSION}/checksums.txt" \
        | grep "$${K9S_TAR}" | awk '{print $1}')
      echo "$${K9S_SHA256}  /tmp/$${K9S_TAR}" | sha256sum -c -
      tar -xz -C /usr/local/bin k9s -f "/tmp/$${K9S_TAR}"
      rm -f "/tmp/$${K9S_TAR}"
    }

    install_kubent() {
      KUBENT_VERSION="0.7.3"
      KUBENT_TAR="kubent-$${KUBENT_VERSION}-linux-amd64.tar.gz"
      curl -fsSL "https://github.com/doitintl/kube-no-trouble/releases/download/$${KUBENT_VERSION}/$${KUBENT_TAR}" \
        -o "/tmp/$${KUBENT_TAR}"
      KUBENT_SHA256=$(curl -fsSL "https://github.com/doitintl/kube-no-trouble/releases/download/$${KUBENT_VERSION}/checksums.txt" \
        | grep "$${KUBENT_TAR}" | awk '{print $1}')
      echo "$${KUBENT_SHA256}  /tmp/$${KUBENT_TAR}" | sha256sum -c -
      tar -xz -C /usr/local/bin -f "/tmp/$${KUBENT_TAR}"
      rm -f "/tmp/$${KUBENT_TAR}"
    }

    install_istioctl() {
      ISTIO_VERSION="1.28.0"
      ISTIO_TAR="istio-$${ISTIO_VERSION}-linux-amd64.tar.gz"
      curl -fsSL "https://github.com/istio/istio/releases/download/$${ISTIO_VERSION}/$${ISTIO_TAR}" \
        -o "/tmp/$${ISTIO_TAR}"
      ISTIO_SHA256=$(curl -fsSL "https://github.com/istio/istio/releases/download/$${ISTIO_VERSION}/$${ISTIO_TAR}.sha256" \
        | awk '{print $1}')
      echo "$${ISTIO_SHA256}  /tmp/$${ISTIO_TAR}" | sha256sum -c -
      tar -xz -C /tmp -f "/tmp/$${ISTIO_TAR}" "istio-$${ISTIO_VERSION}/bin/istioctl"
      mv "/tmp/istio-$${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl
      rm -rf "/tmp/$${ISTIO_TAR}" "/tmp/istio-$${ISTIO_VERSION}"
    }

    export -f install_azure_cli install_helm install_k9s install_kubent install_istioctl
    PIDS=()
    install_azure_cli & PIDS+=($!)
    install_helm      & PIDS+=($!)
    install_k9s       & PIDS+=($!)
    install_kubent    & PIDS+=($!)
    install_istioctl  & PIDS+=($!)
    FAILED=0
    for pid in "$${PIDS[@]}"; do wait "$$pid" || FAILED=$((FAILED+1)); done
    if [[ $$FAILED -gt 0 ]]; then
      echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [ERROR] $${FAILED}개 도구 설치 실패 — /var/log/jumpvm-init.log 확인"
      exit 1
    fi
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] 바이너리 도구 설치 완료"

    # kubectl + kubelogin
    az aks install-cli --install-location /usr/local/bin/kubectl \
      --kubelogin-install-location /usr/local/bin/kubelogin || true

    # User-Assigned Managed Identity로 로그인 (재시도 5회 — identity 전파 지연 대응)
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] MSI 로그인 시도..."
    for i in 1 2 3 4 5; do
      az login --identity --allow-no-subscriptions && break
      echo "[WARN] MSI 로그인 실패 ($i/5), 30초 후 재시도..."
      sleep 30
    done
    az account set --subscription ${var.subscription_id}

    # ---- Terraform 자동 주입 환경변수 ----
    %{if var.prometheus_query_endpoint != ""}
    export PROMETHEUS_URL="${var.prometheus_query_endpoint}"
    %{endif}

    # ---- addon_env 환경변수 주입 ----
    %{for key, value in var.addon_env~}
    export ${key}="${value}"
    %{endfor~}

    # ---- Flux SSH Deploy Key: Key Vault에서 조회 후 파일로 기록 ----
    if [[ -n "${var.key_vault_name}" ]]; then
      FLUX_KEY=$(az keyvault secret show \
        --vault-name "${var.key_vault_name}" \
        --name flux-ssh-private-key \
        --query value -o tsv 2>/dev/null || echo "")
      if [[ -n "$FLUX_KEY" ]]; then
        mkdir -p /root/.ssh
        printf '%s' "$FLUX_KEY" > /root/.ssh/flux-deploy-key
        chmod 600 /root/.ssh/flux-deploy-key
        export GITOPS_SSH_KEY_FILE=/root/.ssh/flux-deploy-key
        echo "[$(date '+%Y-%m-%dT%H:%M:%S')] Flux SSH key loaded from Key Vault"
      fi
    fi

    # AKS credentials 취득
    export KUBECONFIG=/root/.kube/config
    mkdir -p /root/.kube
    %{for name, _ in var.clusters~}
    az aks get-credentials \
      --resource-group ${var.rg_cluster[name]} \
      --name aks-${name} \
      --overwrite-existing
    %{endfor~}

    chmod 600 /root/.kube/config
    kubelogin convert-kubeconfig -l msi

    # Addon 레포 클론 후 설치
    if [[ -n "${var.addon_repo_url}" ]]; then
      REPO_DIR="/opt/addon-repo"
      rm -rf "$REPO_DIR"
      git clone --depth 1 --branch "${var.addon_repo_branch}" \
        "${var.addon_repo_url}" "$REPO_DIR"
      cd "$REPO_DIR"
      chmod +x addons/install.sh
      ./addons/install.sh \
        --prefix ${var.prefix} \
        --location ${var.location}
    else
      echo "[$(date '+%Y-%m-%dT%H:%M:%S')] addon_repo_url 미설정 — 설치 건너뜀"
    fi

    # ~/.bashrc 편의 설정 (var.clusters 기반 동적 생성)
    cat >> /home/${var.jumpbox_admin_username}/.bashrc <<'BASHRC'
# AKS kubeconfig aliases (auto-generated)
%{for name, _ in var.clusters~}
alias kc-${name}='az aks get-credentials -g ${var.rg_cluster[name]} -n aks-${name} --overwrite-existing'
%{endfor~}
alias kc-all='${join(" && ", [for name, _ in var.clusters : "kc-${name}"])}'
export KUBECONFIG=$HOME/.kube/config
BASHRC

    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] cloud-init 완료"
    echo "Jump VM init complete" > /tmp/jumpvm-init.done
    EOF
  )

  tags = var.tags
}

# ============================================================
# P2: Jump VM System-Assigned MI → AKS RBAC Cluster Admin
# 각 AKS 클러스터에서 kubectl 접근 권한 부여 (kubelogin MSI 모드)
# ============================================================

resource "azurerm_role_assignment" "jumpbox_aks_admin" {
  # var.clusters는 static keys(mgmt/app1/app2) — apply 전에도 keys 확정
  for_each = var.clusters

  scope                = azurerm_kubernetes_cluster.aks[each.key].id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azurerm_user_assigned_identity.jumpbox_mi.principal_id
}
