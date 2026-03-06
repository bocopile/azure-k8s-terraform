# Azure Kubernetes 멀티클러스터 IaC

> **OpenTofu** 기반 Azure AKS 멀티클러스터 인프라 코드 (Korea Central)
> 아키텍처 문서: [`document/azure/ARCHITECTURE.md`](document/azure/ARCHITECTURE.md) v3.2.0

---

## 개요

Korea Central Availability Zone(1/2/3)에 **AKS 클러스터 3개**(mgmt / app1 / app2)를 프라이빗 환경으로 구성합니다.
Azure 관리형 서비스를 최대한 활용하고, Spot VM + NAP(Karpenter)으로 비용을 최소화합니다.

| 항목 | 값 |
|---|---|
| IaC 도구 | OpenTofu 1.11+ |
| AKS 버전 | v1.35 |
| 리전 | Korea Central (AZ 1/2/3) |
| 네트워크 | Azure CNI Overlay + Managed Cilium |
| 노드 프로비저닝 | NAP (Node Auto-Provisioning / Karpenter) |
| Service Mesh | AKS Istio Add-on asm-1-28 |
| GitOps | Flux v2 |
| 시크릿 관리 | Azure Key Vault + CSI Driver + External Secrets |
| 관찰성 | Managed Prometheus + Grafana + Container Insights |
| 보안 | Workload Identity + Defender for Containers + Kyverno |

---

## 아키텍처 구성

```
                         ┌─────────────────────────────────┐
                         │        Korea Central             │
                         │                                  │
    Internet ──────────► │  Azure Bastion (Basic)           │
                         │       │                          │
                         │  Jump VM (mgmt VNet)             │
                         │       │                          │
                         │  ┌────┴───────────────────────┐  │
                         │  │  VNet Full-Mesh Peering     │  │
                         │  │  mgmt ↔ app1 ↔ app2        │  │
                         │  └────────────────────────────┘  │
                         │                                  │
                         │  aks-mgmt   aks-app1   aks-app2  │
                         │  (Private)  (Private)  (Private) │
                         └─────────────────────────────────┘
                                        │
                         ┌─────────────────────────────────┐
                         │     공유 관리형 서비스            │
                         │  ACR · Key Vault(PE) · Grafana   │
                         │  Log Analytics · Monitor WS      │
                         │  Backup Vault · Sentinel(선택)   │
                         └─────────────────────────────────┘
```

### 클러스터 역할

| 클러스터 | VNet | Ingress Pool | 역할 |
|---|---|---|---|
| `aks-mgmt` | 10.1.0.0/16 | ✅ | 모니터링·GitOps·관리 워크로드 |
| `aks-app1` | 10.2.0.0/16 | ✅ | 운영 애플리케이션 |
| `aks-app2` | 10.3.0.0/16 | ❌ | 배치·백그라운드 워크로드 |

---

## 디렉터리 구조

```
.
├── main.tf                  # Provider 설정 + 모듈 오케스트레이션
├── locals.tf                # 공통 로컬 값 (리전, CIDR, 이름 등)
├── variables.tf             # 입력 변수 (필수 + 환경별 선택)
├── outputs.tf               # 루트 레벨 출력
├── federation.tf            # Workload Identity Federated Credentials
├── flow-logs.tf             # NSG Flow Logs + Traffic Analytics
├── terraform.tfvars.example # 변수 입력 예시
│
├── modules/
│   ├── resource-group/      # Resource Group 생성 (공통 + 클러스터별)
│   ├── network/             # VNet · Subnet · NSG · Peering · Private DNS Zone
│   ├── identity/            # Managed Identity + Role Assignments
│   ├── keyvault/            # Key Vault (Private Endpoint + RBAC)
│   ├── acr/                 # Azure Container Registry
│   ├── monitoring/          # Log Analytics · Monitor WS · Grafana · Sentinel
│   ├── backup/              # Backup Vault + AKS Backup Policy
│   └── aks/                 # AKS 클러스터 · Node Pool · Bastion · Jump VM
│       ├── main.tf
│       ├── diagnostics.tf   # AKS Control Plane 진단 설정
│       ├── prometheus.tf    # DCE · DCR · DCRA (Managed Prometheus)
│       └── alerts.tf        # CPU · Memory · CrashLoopBackOff 알림
│
├── addons/
│   ├── install.sh           # Phase 2 진입점
│   └── scripts/             # 19개 애드온 설치 스크립트
│
└── document/azure/          # 아키텍처 문서
    ├── ARCHITECTURE.md
    ├── DIAGRAMS.md
    └── IaC-REVIEW.md
```

### 모듈 의존성 그래프

```
resource-group
  └── network
        ├── monitoring
        │     └── keyvault
        ├── acr (독립)
        ├── backup (독립)
        └── identity ──────► aks
                               └── federation.tf (루트, AKS 생성 후)
```

---

## 사전 준비

### 필수 도구

```bash
# Phase 1 (인프라 배포)
brew install opentofu        # >= 1.11.0
brew install azure-cli

# Phase 2 (애드온 설치 — Jump VM 또는 로컬 환경)
brew install kubectl
brew install helm
brew install azure/kubelogin/kubelogin

# 버전 확인
tofu version      # >= 1.11.0
az version
kubectl version --client
helm version
```

### Azure 연결

```bash
# 1. 로그인
az login
az account set --subscription "<SUBSCRIPTION_ID>"

# subscription_id / tenant_id 확인 (terraform.tfvars에 입력할 값)
az account show --query "{subscription_id:id, tenant_id:tenantId}" -o table

# 2. Resource Provider 등록
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Monitor
az provider register --namespace Microsoft.Dashboard
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.ContainerRegistry
az provider register --namespace Microsoft.DataProtection
az provider register --namespace Microsoft.SecurityInsights
az provider register --namespace Microsoft.Insights
az provider register --namespace Microsoft.ManagedIdentity
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Storage

# 3. NAP (Karpenter)는 GA되어 별도 Feature Flag 등록이 불필요합니다.
#    위 Resource Provider 등록만 완료하면 node_provisioning_profile { mode = "Auto" } 사용 가능합니다.
```

### vCPU 쿼터 확인 및 증가

AKS 클러스터 3개를 생성하려면 충분한 vCPU 쿼터가 필요합니다.

```bash
# 현재 쿼터 확인 (Dedicated + Spot 모두)
az vm list-usage --location koreacentral -o table \
  | grep -E "DSv4|Total Regional|Low-priority"
```

**필요 쿼터 (기본 설정 기준):**

| 쿼터 | 리소스 이름 | 필요량 | 산출 근거 |
|---|---|---|---|
| Standard DSv4 Family vCPUs | `standardDSv4Family` | 20+ | 3클러스터 × system 3노드 × 2vCPU = 18 |
| Total Regional vCPUs | `cores` | 30+ | DSv4 18 + Spot 12 + Jump VM 2 |
| Total Regional Low-priority (Spot) vCPUs | `lowPriorityCores` | 20+ | 2클러스터(mgmt,app1) × ingress 3노드 × 2vCPU = 12 |

> **Spot(Low-priority) 쿼터란?**
> Ingress 노드 풀은 비용 절감을 위해 Spot VM을 사용합니다.
> Spot VM은 Dedicated 쿼터와 별도인 **Low-priority 쿼터**를 소비합니다.
> 기본 할당량이 매우 낮으므로(보통 3) 반드시 증가가 필요합니다.

#### 쿼터 증가 방법 (CLI)

쿼터가 부족하면 `tofu apply` 시 `ErrCode_InsufficientVCPUQuota` 또는
`OperationNotAllowed (LowPriorityCores)` 에러가 발생합니다.

```bash
# 1. quota 확장 설치 (최초 1회)
az extension add --name quota

# 2. 구독 ID 변수 설정
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SCOPE="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Compute/locations/koreacentral"

# 3. Standard DSv4 Family → 20 vCPU
az quota create \
  --resource-name "standardDSv4Family" \
  --scope "$SCOPE" \
  --limit-object value=20 \
  --resource-type "dedicated"

# 4. Total Regional vCPU → 30
az quota create \
  --resource-name "cores" \
  --scope "$SCOPE" \
  --limit-object value=30 \
  --resource-type "dedicated"

# 5. Low-priority (Spot) vCPU → 20
az quota create \
  --resource-name "lowPriorityCores" \
  --scope "$SCOPE" \
  --limit-object value=20 \
  --resource-type "dedicated"

# 6. 반영 확인 (수 초 ~ 수 분 소요)
az vm list-usage --location koreacentral -o table \
  | grep -E "DSv4 Family|Total Regional|Low-priority"
```

> 다른 VM 패밀리를 사용하는 경우 `--resource-name`을 해당 패밀리로 변경합니다.
> (예: `standardDSv5Family`, `standardDASv4Family` 등)
>
> 쿼터 변경이 즉시 반영되지 않으면 수 분 후 다시 확인하세요.
> 일부 구독에서는 자동 승인이 아닌 수동 검토가 필요할 수 있습니다.

### Rocky Linux Marketplace 약관 동의

Jump VM이 Rocky Linux를 사용하므로 최초 배포 전 약관 동의가 필요합니다.

```bash
az vm image terms accept --publisher resf --offer rockylinux-x86_64 --plan 9-base
```

### 권한 요구사항

Role Assignment를 생성하므로 **`Owner`** 또는 **`Contributor + User Access Administrator`** 조합이 필요합니다.

```bash
az role assignment list \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --scope /subscriptions/$(az account show --query id -o tsv) \
  --output table
```

---

## 빠른 시작

### 1. 변수 파일 작성

```bash
cp terraform.tfvars.example terraform.tfvars
```

#### subscription_id / tenant_id 조회

```bash
# 현재 로그인된 구독의 ID와 테넌트 ID 한 번에 확인
az account show --query "{subscription_id:id, tenant_id:tenantId}" -o table

# 여러 구독이 있는 경우 — 전체 목록 확인 후 선택
az account list --query "[].{name:name, id:id, state:state}" -o table
az account set --subscription "<SUBSCRIPTION_ID>"

# 선택된 구독 최종 확인
az account show --query "{subscription_id:id, tenant_id:tenantId}" -o tsv
```

`terraform.tfvars` 필수 항목:

```hcl
# az account show 출력값을 그대로 붙여넣기
subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
tenant_id       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# 전세계 유니크 이름 (5-50 alphanumeric)
# 예: "acrk8s" + 구독 ID 뒷 6자리
acr_name  = "myacr<유니크문자열>"

# Key Vault + Storage Account 접미사 (3-8 alphanumeric)
# 최종 이름: kv-k8s-<kv_suffix> / stk8s<kv_suffix>fl
kv_suffix = "abc123"

# SSH 공개키 문자열 (파일 경로 아님 — cat ~/.ssh/id_rsa_jumpbox.pub 출력값)
jumpbox_ssh_public_key = "ssh-rsa AAAA..."
```

> **SSH 키가 없는 경우 (No such file or directory)**
>
> ```bash
> # 1. 키 쌍 생성 (비밀번호 없이 바로 Enter)
> ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_jumpbox -C "jumpbox"
>
> # 2. 공개키 내용 확인 → 출력값 전체를 jumpbox_ssh_public_key에 붙여넣기
> cat ~/.ssh/id_rsa_jumpbox.pub
> ```
>
> - `~/.ssh` 디렉토리가 없으면 `ssh-keygen`이 자동 생성합니다.
> - 기존 `~/.ssh/id_rsa.pub`가 있다면 그대로 사용해도 됩니다.

### 1-b. Flux SSH Deploy Key 준비

Flux GitOps를 활성화하려면 SSH Deploy Key가 필요합니다.
`addon_repo_url`을 설정하면 `tofu apply` 중에 자동으로 처리됩니다.

```bash
# 1. ed25519 키 쌍 생성 (비밀번호 없이)
ssh-keygen -t ed25519 -C flux-deploy -f ~/.ssh/flux-deploy-key -N ''

# 생성된 파일 확인
ls -la ~/.ssh/flux-deploy-key*
# ~/.ssh/flux-deploy-key      ← 비밀키 (terraform.tfvars에 등록)
# ~/.ssh/flux-deploy-key.pub  ← 공개키 (GitHub/GitLab에 등록)

# 2. 공개키 내용 확인 → GitHub Deploy Key로 등록
cat ~/.ssh/flux-deploy-key.pub
```

> **GitHub 공개키 등록 위치**
> GitOps 레포 → Settings → Deploy keys → Add deploy key
> - Title: `flux-deploy`
> - Key: 위 명령 출력값 전체 붙여넣기
> - Allow write access: 체크 불필요 (read-only)

```bash
# 3. terraform.tfvars에 비밀키 등록
# (file() 함수는 tofu apply 실행 시 로컬 파일을 읽어 Key Vault에 저장)
cat >> terraform.tfvars <<'EOF'

# Flux SSH Deploy Key (Key Vault에 안전하게 저장됨)
flux_ssh_private_key = file("~/.ssh/flux-deploy-key")
EOF
```

### 1-c. Addon 자동 설치 설정 (addon_env)

`addon_repo_url`을 설정하면 `tofu apply` 완료 후 Jump VM이 자동으로 `install.sh`를 실행합니다.

```bash
# terraform.tfvars에 추가 (실제 값으로 교체)
cat >> terraform.tfvars <<'EOF'

# Git 레포 URL (이 프로젝트 또는 fork URL)
addon_repo_url = "https://github.com/your-org/azure-k8s-terraform.git"

# install.sh에 주입할 환경변수
addon_env = {
  # cert-manager ClusterIssuer (필수)
  LETSENCRYPT_EMAIL     = "admin@example.com"
  AZURE_SUBSCRIPTION_ID = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  AZURE_TENANT_ID       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

  # Flux GitOps (addon_repo_url 설정 시 필수)
  GITOPS_REPO_URL = "ssh://git@github.com/your-org/gitops-repo.git"
  GITOPS_BRANCH   = "main"
  GITOPS_PATH     = "clusters"

  # DNS-01 챌린지 (DNS Zone 있을 때만 — 없으면 HTTP-01 fallback)
  DNS_ZONE_NAME          = ""
  DNS_ZONE_RG            = ""
  CERT_MANAGER_CLIENT_ID = ""

  # Kiali (선택 — Azure Managed Prometheus 쿼리 URL)
  PROMETHEUS_URL  = ""
  GRAFANA_ENABLED = "false"
}
EOF
```

> **addon_env를 설정하지 않으면** `tofu apply`는 정상 동작하지만 install.sh에서
> `LETSENCRYPT_EMAIL`이 없어 cert-manager ClusterIssuer 생성이 실패합니다.
> Flux를 사용하지 않는다면 `flux_ssh_private_key`와 `GITOPS_REPO_URL`은 생략 가능합니다.

> **addon_repo_url을 비워두면** CustomScript Extension이 실행되지 않고
> Jump VM만 준비됩니다. 이후 수동으로 Bastion → Jump VM 접속 후 `install.sh`를 실행할 수 있습니다.

### 2. AKS 버전 확인

```bash
# 마이너 버전 목록 확인
az aks get-versions --location koreacentral \
  --query "values[].version" -o table

# 패치 버전까지 상세 확인
az aks get-versions --location koreacentral \
  --query "values[].patchVersions.keys(@)[]" -o table
```

`variables.tf`의 `kubernetes_version` 기본값(또는 `terraform.tfvars` 오버라이드)이 가용 버전 목록에 있는지 확인합니다.

### 3. 초기화 및 배포

```bash
# 초기화
tofu init

# 검증
tofu validate

# 플랜 확인
tofu plan -out=tfplan

# (필요 시) Network Watcher import
# Azure가 VNet 생성 시 NetworkWatcher_koreacentral을 자동 생성하는 경우
tofu import azurerm_network_watcher.nw \
  /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/NetworkWatcher_koreacentral

# 배포 (약 25~35분 소요)
tofu apply tfplan
```

### 4. 배포 후 모니터링 체크리스트

`tofu apply` 완료 직후 아래 순서로 정상 여부를 확인한다.
이상이 발견되면 해당 체크포인트에서 멈추고 [크리티컬 장애 대응](#크리티컬-장애-대응) 절차를 따른다.

#### 4-1. 노드 상태

```bash
# 3개 클러스터 모두 Ready 노드 확인
for c in mgmt app1 app2; do
  echo "=== aks-${c} ==="
  az aks command invoke -g "rg-k8s-${c}" -n "aks-${c}" \
    --command "kubectl get nodes -o wide"
done
```

| 기대값 | 이상 징후 |
|--------|-----------|
| 각 클러스터 system 노드 3개 Ready | NotReady / Pending 노드 존재 |
| ingress 노드 Spot 할당 완료 (mgmt, app1) | 노드 0개 (Spot 자원 부족) |

---

#### 4-2. 시스템 Pod 상태

```bash
for c in mgmt app1 app2; do
  echo "=== aks-${c} ==="
  az aks command invoke -g "rg-k8s-${c}" -n "aks-${c}" \
    --command "kubectl get pods -n kube-system --field-selector=status.phase!=Running"
done
```

| 기대값 | 이상 징후 |
|--------|-----------|
| kube-system Pod 모두 Running | CrashLoopBackOff / ImagePullBackOff |
| coredns / cilium-agent Ready | Pending 상태 지속 (노드 자원 부족) |

---

#### 4-3. 네트워크 연결성

```bash
# VNet 피어링 상태 확인 (Connected 이어야 함)
az network vnet peering list -g rg-k8s-mgmt --vnet-name vnet-mgmt -o table
az network vnet peering list -g rg-k8s-app1 --vnet-name vnet-app1 -o table

# Private DNS Zone 링크 확인
az network private-dns link vnet list \
  -g rg-k8s-common \
  -z privatelink.koreacentral.azmk8s.io \
  -o table
```

| 기대값 | 이상 징후 |
|--------|-----------|
| Peering Status: Connected | Disconnected / Initiated |
| DNS 링크 3개 (mgmt / app1 / app2) | 링크 누락 → kubectl FQDN 해석 실패 |

---

#### 4-4. 공유 서비스 상태

```bash
# Key Vault Private Endpoint 연결
az network private-endpoint show \
  -g rg-k8s-common -n pe-kv-k8s \
  --query "customDnsConfigs" -o table

# ACR 접근 (Kubelet Identity 권한 확인)
az acr check-health -n <acr_name> --ignore-errors

# Managed Grafana (배포 완료 URL 출력)
tofu output grafana_endpoint
```

---

#### 4-5. Workload Identity 페더레이션

```bash
# federation.tf 로 생성된 Federated Credential 확인
az identity federated-credential list \
  --identity-name id-k8s-workload \
  -g rg-k8s-common \
  -o table
```

---

### 크리티컬 장애 대응

아래 상황이 발생하면 **`tofu apply` 를 중단하고** 원인을 제거한 뒤 재시도한다.

#### STOP 기준

| 증상 | 판단 기준 | 대응 |
|------|-----------|------|
| 노드 NotReady 지속 (5분+) | `kubectl describe node` 에서 kubelet 오류 | 아래 [A] 참조 |
| AKS 프로비저닝 실패 | `tofu apply` 에러 또는 Portal에서 Failed | 아래 [B] 참조 |
| Spot 노드 0개 (할당 불가) | ingress 노드풀 nodeCount=0 | 아래 [C] 참조 |
| VNet Peering Disconnected | 클러스터 간 통신 불가 | 아래 [D] 참조 |
| Backup Vault 생성 실패 | `tofu apply` 에서 DataProtection 오류 | 아래 [E] 참조 |

---

**[A] 노드 NotReady**

```bash
# 노드 상태 상세 확인
az aks command invoke -g rg-k8s-<cluster> -n aks-<cluster> \
  --command "kubectl describe node <node-name> | tail -30"

# AKS 진단 로그 확인 (Control Plane)
az aks show -g rg-k8s-<cluster> -n aks-<cluster> \
  --query "provisioningState"

# 대응: 노드풀 업그레이드/재시작
az aks nodepool upgrade \
  -g rg-k8s-<cluster> -n aks-<cluster> \
  --nodepool-name system --kubernetes-version <current-version>
```

**[B] AKS 프로비저닝 실패**

```bash
# 실패 원인 확인
az aks show -g rg-k8s-<cluster> -n aks-<cluster> \
  --query "{state:provisioningState, error:powerState}" -o json

# state 충돌 시: state에서 제거 후 import 또는 재생성
tofu state rm module.aks_<cluster>.azurerm_kubernetes_cluster.<cluster>
tofu apply -target=module.aks_<cluster>
```

**[C] Spot 노드 할당 불가**

```bash
# 현재 Spot 할당 가능 SKU 확인
az vm list-skus --location koreacentral \
  --query "[?resourceType=='virtualMachines' && contains(name,'Standard_D2s')]" \
  -o table

# 임시 대응: ingress 노드풀을 Dedicated로 전환 (variables.tf 수정 후 apply)
# vm_size_ingress = "Standard_D2s_v5"  # priority = Regular 로 변경
```

**[D] VNet Peering Disconnected**

```bash
# 피어링 재연결 (tofu taint 후 재생성)
tofu taint module.network_mgmt.azurerm_virtual_network_peering.mgmt_to_app1
tofu apply -target=module.network_mgmt
```

**[E] Backup Vault 생성 실패**

```bash
# DataProtection Provider 등록 상태 확인
az provider show -n Microsoft.DataProtection \
  --query "registrationState" -o tsv

# Registered 아니면:
az provider register --namespace Microsoft.DataProtection
# 등록 완료(1~2분) 후 재시도
tofu apply -target=module.backup
```

> **재배포 시 주의사항 (RG 삭제 후 재생성)**
>
> Subscription 레벨 리소스는 RG 삭제 시 자동으로 사라지지 않습니다.
> 기존 배포를 삭제 후 재배포할 때는 아래 정리를 먼저 수행하세요.
>
> ```bash
> # 1. 기존 구독 레벨 Diagnostic Setting 삭제 (Activity Log → LAW)
> az monitor diagnostic-settings delete \
>   --name "diag-activity-to-law" \
>   --resource "/subscriptions/<SUBSCRIPTION_ID>"
>
> # 2. 기존 Terraform state 초기화
> rm -f terraform.tfstate terraform.tfstate.backup \
>      terraform.tfstate.old terraform.tfstate.backup.old
>
> # 3. 재초기화 및 배포
> tofu init && tofu plan -out=tfplan && tofu apply tfplan
> ```
>
> 또는 import로 기존 리소스를 state에 등록할 수도 있습니다:
> ```bash
> tofu import 'module.monitoring.azurerm_monitor_diagnostic_setting.activity_log' \
>   '/subscriptions/<SUBSCRIPTION_ID>|diag-activity-to-law'
> ```
```

---

## Phase 2 — 애드온 설치

### 자동 설치 (권장)

`terraform.tfvars`에 `addon_repo_url`을 설정하면 **`tofu apply` 한 번으로 전체 배포**가 완료됩니다.

```
tofu apply
  ├── 인프라 생성 (AKS 3개, Key Vault, Backup 등)
  ├── flux-ssh-private-key → Key Vault secret 저장
  └── CustomScript Extension (Jump VM에서 백그라운드 실행)
        ① addon_env 환경변수 export
        ② Key Vault에서 Flux SSH key 조회
        ③ addon_repo_url 레포 클론
        └── install.sh --cluster all 자동 실행
```

설치 로그 확인 (Jump VM 접속 후):
```bash
# Azure Portal → vm-jumpbox → Bastion 접속 후
tail -f /var/log/jumpvm-addon.log
```

### 수동 설치 (addon_repo_url 미설정 시)

```bash
# Jump VM 접속 (Azure Bastion 경유)
# Azure Portal → Virtual Machines → vm-jumpbox → Connect → Bastion

# 클러스터 kubeconfig 설정
kc-all   # alias: 3개 클러스터 kubeconfig 일괄 설정

# 전체 애드온 설치
cd ~/azure-k8s-terraform
./addons/install.sh --cluster all

# 특정 클러스터만
./addons/install.sh --cluster mgmt

# Dry-run (실제 설치 없이 확인)
./addons/install.sh --cluster all --dry-run
```

### 설치 순서 (20개 스크립트, 14번은 최종 검증으로 마지막 실행)

| 단계 | 스크립트 | 내용 |
|---|---|---|
| 00 | `00-priority-classes.sh` | PriorityClass 정의 |
| 00b | `00b-gateway-api.sh` | Gateway API CRDs (v1.5.0) |
| 01 | `01-cert-manager.sh` | cert-manager + ClusterIssuer (Let's Encrypt) |
| 02 | `02-external-secrets.sh` | External Secrets Operator |
| 03 | `03-reloader.sh` | Stakater Reloader |
| 04 | `04-istio.sh` | AKS Istio Add-on (asm-1-28) |
| 04b | `04b-istio-mtls.sh` | mTLS STRICT (PeerAuthentication + DestinationRule) |
| 05 | `05-kyverno.sh` | Kyverno 정책 엔진 |
| 06 | `06-flux.sh` | Flux v2 GitOps + FluxConfig |
| 07 | `07-kiali.sh` | Kiali v2.22 + Kiali CR |
| 08 | `08-karpenter-nodepool.sh` | NAP NodePool CRD (Spot 전용) |
| 09 | `09-backup-extension.sh` | AKS Backup 상태 확인 (Extension은 Terraform 관리) |
| 10 | `10-defender.sh` | Defender for Containers 검증 |
| 11 | `11-budget-alert.sh` | 예산 알림 ($250/월) |
| 12 | `12-aks-automation.sh` | AKS Stop/Start 자동화 (STUB) |
| 13 | `13-hubble.sh` | Cilium Hubble UI + Relay |
| 15 | `15-tetragon.sh` | Cilium Tetragon (eBPF 런타임 보안) |
| 16 | `16-otel-collector.sh` | OpenTelemetry Collector |
| 19 | `19-vpa.sh` | Vertical Pod Autoscaler (recommend-only) |
| 14 | `14-verify-clusters.sh` | 설치 검증 (항상 마지막) |

---

## 주요 변수

| 변수 | 필수 | 기본값 | 설명 |
|---|---|---|---|
| `subscription_id` | ✅ | — | Azure 구독 ID |
| `tenant_id` | ✅ | — | Azure AD 테넌트 ID |
| `acr_name` | ✅ | — | ACR 이름 (전역 유니크, 5-50 alphanumeric) |
| `kv_suffix` | ✅ | — | Key Vault + Storage 접미사 (3-8 alphanumeric) |
| `jumpbox_ssh_public_key` | ✅ | — | Jump VM SSH 공개키 문자열 |
| `jumpbox_admin_username` | ❌ | `azureadmin` | Jump VM 관리자 계정명 |
| `enable_grafana` | ❌ | `true` | Azure Managed Grafana 활성화 |
| `enable_sentinel` | ❌ | `false` | Microsoft Sentinel 활성화 |
| `dns_zone_id` | ❌ | `""` | cert-manager DNS-01용 Azure DNS Zone ID |
| `tags` | ❌ | project/env/managed_by | 공통 리소스 태그 |
| `location` | ❌ | `koreacentral` | Azure 리전 |
| `prefix` | ❌ | `k8s` | 리소스 이름 접두사 |
| `kubernetes_version` | ❌ | `1.34` | AKS Kubernetes 버전 |
| `vm_size_system` | ❌ | `Standard_D2s_v5` | System 노드풀 VM SKU |
| `vm_size_ingress` | ❌ | `Standard_D2s_v5` | Ingress 노드풀 VM SKU |
| `vm_size_jumpbox` | ❌ | `Standard_B2s` | Jump VM SKU |
| `aks_sku_tier` | ❌ | `Standard` | AKS SKU 티어 (Free / Standard) |
| `acr_sku` | ❌ | `Basic` | ACR SKU (Basic / Standard / Premium) |
| `bastion_sku` | ❌ | `Basic` | Azure Bastion SKU (Basic / Standard) |
| `keyvault_sku` | ❌ | `standard` | Key Vault SKU (standard / premium) |
| `log_retention_days` | ❌ | `30` | Log Analytics 보존 기간 (일) |
| `flow_log_retention_days` | ❌ | `30` | NSG Flow Log 보존 기간 (일) |
| `backup_retention_duration` | ❌ | `P7D` | Backup Vault 보존 기간 (ISO 8601) |
| `keyvault_purge_protection` | ❌ | `true` | Key Vault Purge Protection 활성화 (demo: false) |
| `grafana_public_access` | ❌ | `true` | Grafana Public 접근 허용 (prod: false + PE 필요) |
| `grafana_sku` | ❌ | `Standard` | Grafana SKU (Standard / Essential) |
| `backup_soft_delete` | ❌ | `false` | Backup Vault Soft Delete (prod: true 권장) |
| `addon_repo_url` | ❌ | `""` | Addon 스크립트 git 레포 URL (설정 시 자동 설치) |
| `addon_env` | ❌ | `{}` | install.sh 환경변수 맵 (`LETSENCRYPT_EMAIL` 등) |
| `flux_ssh_private_key` | ❌ | `""` | Flux SSH 비밀키 (Key Vault에 저장, `file()` 사용) |

---

## 주요 출력값

```bash
# 배포 완료 후 확인
tofu output

# 클러스터 접속 명령어
tofu output kubeconfig_commands

# Jump VM IP
tofu output jumpbox_private_ip

# Key Vault URI
tofu output key_vault_uri

# ACR 로그인 서버
tofu output acr_login_server

# Phase 2 시작 명령어
tofu output phase2_command
```

---

## 네트워크 구성

| 구분 | CIDR | 용도 |
|---|---|---|
| mgmt VNet | 10.1.0.0/16 | 관리 클러스터 + Bastion + Jump VM |
| app1 VNet | 10.2.0.0/16 | 운영 클러스터 1 |
| app2 VNet | 10.3.0.0/16 | 운영 클러스터 2 |
| AKS Subnet (각 VNet) | 10.x.0.0/22 | AKS 노드 (CNI Overlay) |
| AzureBastionSubnet | 10.1.100.0/26 | Azure Bastion |
| Jumpbox Subnet | 10.1.1.0/24 | Jump VM (Static IP: 10.1.1.10) |
| Private Endpoint Subnet | 10.1.2.0/24 | Key Vault PE |

**VNet 연결**: mgmt ↔ app1 ↔ app2 풀메시 피어링
**Private DNS Zone**: `privatelink.koreacentral.azmk8s.io` 공유 (3개 VNet 링크) → Jump VM에서 모든 클러스터 API FQDN 해석 가능

---

## 보안 설계

- **접근 경로**: 인터넷 → Azure Bastion → Jump VM → Private AKS API Server
- **인증**: Azure RBAC for Kubernetes (로컬 계정 비활성화)
- **시크릿**: Key Vault Private Endpoint + CSI Driver + Workload Identity
- **이미지 보안**: ACR + AcrPull (Kubelet Identity) — admin 계정 비활성화
- **런타임 보안**: Defender for Containers + Cilium Tetragon (eBPF)
- **정책**: Kyverno + Azure Policy (PSA baseline)

---

## 인프라 삭제

```bash
# Step 1: K8s 레벨 리소스 사전 정리 (VPN / Jump VM 불필요 — az aks command invoke 사용)
./scripts/pre-destroy.sh --dry-run   # 삭제 대상 확인
./scripts/pre-destroy.sh             # 실제 정리 실행

# Step 2: 인프라 삭제
tofu plan -destroy                   # 삭제 대상 검토
tofu destroy
```

> 자세한 삭제 절차 (Key Vault purge, 잔여 리소스 확인 등)는 [`DESTROY.md`](DESTROY.md) 참조.

---

## Blob State 전환 (선택)

```bash
# 1. Storage Account + Container 생성
az storage account create \
  --name <globally-unique-name> \
  --resource-group rg-tfstate \
  --sku Standard_LRS

az storage container create \
  --name tfstate \
  --account-name <globally-unique-name>

# 2. main.tf backend "azurerm" 블록 주석 해제 후 backend "local" {} 제거

# 3. State 이전
tofu init -migrate-state

# 4. 로컬 State 파일 제거
rm terraform.tfstate terraform.tfstate.backup
```

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `tofu apply` 시 Network Watcher 충돌 | Azure가 VNet 생성 시 자동 생성 | `tofu import azurerm_network_watcher.nw /subscriptions/.../NetworkWatcher_koreacentral` |
| Key Vault 이름 충돌 (`SoftDeleted`) | 이전 삭제 후 soft-delete 상태 잔존 | `az keyvault purge --name <kv-name>` |
| AKS 버전 미지원 | 리전별 가용 버전 상이 | `az aks get-versions --location koreacentral` 확인 |
| VM 할당량 초과 | 구독별 vCPU 할당량 제한 | `az vm list-usage --location koreacentral -o table` 확인 후 할당량 증가 요청 |
| Private Cluster API 접근 불가 | Jump VM 또는 VPN 경유 필요 | ① Azure Bastion → Jump VM 접속 후 kubectl 사용, 또는 ② `az aks command invoke`로 VPN 없이 직접 실행 |
| Addon 스크립트 prefix 불일치 | `install.sh --prefix`와 Terraform `var.prefix` 불일치 | 동일 prefix 값 사용 필수 |

---

## 참고 문서

| 문서 | 내용 |
|---|---|
| [`document/azure/ARCHITECTURE.md`](document/azure/ARCHITECTURE.md) | 전체 아키텍처 설계 (v3.2.0) |
| [`document/azure/DIAGRAMS.md`](document/azure/DIAGRAMS.md) | Mermaid 아키텍처 다이어그램 |
| [`document/azure/IaC-REVIEW.md`](document/azure/IaC-REVIEW.md) | IaC 구현 검토 및 개선 계획 |
| [`document/azure/PROMPT.md`](document/azure/PROMPT.md) | 프로젝트 설계 프롬프트 |
| [`terraform.tfvars.example`](terraform.tfvars.example) | 변수 입력 예시 |
