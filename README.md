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
| AKS 버전 | v1.34 |
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
├── variables.tf             # 전역 유니크 필수 입력 변수
├── outputs.tf               # 루트 레벨 출력
├── federation.tf            # Workload Identity Federated Credentials
├── flow-logs.tf             # NSG Flow Logs + Traffic Analytics
├── terraform.tfvars.example # 변수 입력 예시
│
├── modules/
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
│   └── scripts/             # 16개 애드온 설치 스크립트
│
└── document/azure/          # 아키텍처 문서
    ├── ARCHITECTURE.md
    ├── DIAGRAMS.md
    └── IaC-REVIEW.md
```

### 모듈 의존성 그래프

```
network
  ├── monitoring
  │     └── keyvault
  ├── acr
  ├── (keyvault)
  └── identity ──────► aks
                         └── federation.tf (루트, AKS 생성 후)
```

---

## 사전 준비

### 필수 도구

```bash
# OpenTofu 설치 (macOS)
brew install opentofu

# Azure CLI
brew install azure-cli

# 버전 확인
tofu version      # >= 1.11.0
az version
```

### Azure 연결

```bash
# 1. 로그인
az login
az account set --subscription "<SUBSCRIPTION_ID>"

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

# 3. NAP (Karpenter) Preview Feature 등록 — 필수
az feature register \
  --namespace Microsoft.ContainerService \
  --name NodeAutoProvisioningPreview

# 등록 완료 확인 (Registered 상태까지 대기)
az feature show \
  --namespace Microsoft.ContainerService \
  --name NodeAutoProvisioningPreview \
  --query properties.state -o tsv

# Feature 등록 후 Provider 재등록
az provider register --namespace Microsoft.ContainerService
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

`terraform.tfvars` 필수 항목:

```hcl
subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
tenant_id       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# 전세계 유니크 이름 (5-50 alphanumeric)
acr_name  = "myacr<유니크문자열>"

# Key Vault + Storage Account 접미사 (3-8 alphanumeric)
# 최종 이름: kv-k8s-demo-<kv_suffix> / stk8sdemo<kv_suffix>fl
kv_suffix = "abc123"

# SSH 공개키 문자열 (파일 경로 아님 — cat ~/.ssh/id_rsa.pub 출력값)
jumpbox_ssh_public_key = "ssh-rsa AAAA..."
```

### 2. AKS 버전 확인

```bash
az aks get-versions --location koreacentral \
  --query "orchestrators[].orchestratorVersion" -o table
```

`locals.tf`의 `kubernetes_version`이 가용 버전 목록에 있는지 확인합니다.

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

---

## Phase 2 — 애드온 설치

인프라 배포 완료 후 Jump VM에서 실행합니다.

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

### 설치 순서 (16개 스크립트)

| 단계 | 스크립트 | 내용 |
|---|---|---|
| 00 | `00-priority-classes.sh` | PriorityClass 정의 |
| 00b | `00b-gateway-api.sh` | Gateway API CRDs (v1.3.0) |
| 01 | `01-cert-manager.sh` | cert-manager + Workload Identity |
| 02 | `02-external-secrets.sh` | External Secrets Operator |
| 03 | `03-reloader.sh` | Stakater Reloader |
| 04 | `04-istio.sh` | AKS Istio Add-on (asm-1-28) |
| 05 | `05-kyverno.sh` | Kyverno 정책 엔진 v3.7.1 |
| 06 | `06-flux.sh` | Flux v2 GitOps |
| 07 | `07-kiali.sh` | Kiali 서비스 메시 대시보드 v2.21 |
| 08 | `08-karpenter-nodepool.sh` | NAP NodePool CRD (cpu≤20, mem≤40Gi) |
| 09 | `09-backup-extension.sh` | AKS Backup Extension |
| 10 | `10-defender.sh` | Defender for Containers |
| 11 | `11-budget-alert.sh` | 예산 알림 |
| 12 | `12-aks-automation.sh` | AKS Automation |
| 13 | `13-hubble.sh` | Cilium Hubble UI |
| 14 | `14-verify-clusters.sh` | 설치 검증 |

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
# 전체 리소스 삭제 (순서 자동 처리)
tofu destroy

# 주의: Backup Vault soft_delete = false (demo 설정)
# prod 환경에서는 BackupInstance 먼저 제거 후 destroy 권장
```

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

## 참고 문서

| 문서 | 내용 |
|---|---|
| [`document/azure/ARCHITECTURE.md`](document/azure/ARCHITECTURE.md) | 전체 아키텍처 설계 (v3.2.0) |
| [`document/azure/DIAGRAMS.md`](document/azure/DIAGRAMS.md) | Mermaid 아키텍처 다이어그램 |
| [`document/azure/IaC-REVIEW.md`](document/azure/IaC-REVIEW.md) | IaC 구현 검토 및 개선 계획 |
| [`terraform.tfvars.example`](terraform.tfvars.example) | 변수 입력 예시 |
