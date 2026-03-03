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

# 커스텀 prefix + location 사용 (기본값: k8s-demo / koreacentral)
./addons/install.sh --cluster all --prefix my-project --location koreacentral

# Dry-run (실제 설치 없이 확인)
./addons/install.sh --cluster all --dry-run
```

### 설치 순서 (19개 스크립트, 14번은 최종 검증으로 마지막 실행)

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
| 09 | `09-backup-extension.sh` | AKS Backup Extension (BackupInstance는 수동) |
| 10 | `10-defender.sh` | Defender for Containers 검증 |
| 11 | `11-budget-alert.sh` | 예산 알림 ($250/월) |
| 12 | `12-aks-automation.sh` | AKS Stop/Start 자동화 (STUB — 미구현) |
| 13 | `13-hubble.sh` | Cilium Hubble UI + Relay |
| 15 | `15-tetragon.sh` | Cilium Tetragon (eBPF 런타임 보안) |
| 16 | `16-otel-collector.sh` | OpenTelemetry Collector (분산 트레이싱) |
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
| `prefix` | ❌ | `k8s-demo` | 리소스 이름 접두사 |
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
| `grafana_public_access` | ❌ | `false` | Grafana Public 접근 허용 (demo: true) |
| `grafana_sku` | ❌ | `Standard` | Grafana SKU (Standard / Essential) |
| `backup_soft_delete` | ❌ | `false` | Backup Vault Soft Delete (prod: true 권장) |

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

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `tofu apply` 시 Network Watcher 충돌 | Azure가 VNet 생성 시 자동 생성 | `tofu import azurerm_network_watcher.nw /subscriptions/.../NetworkWatcher_koreacentral` |
| Key Vault 이름 충돌 (`SoftDeleted`) | 이전 삭제 후 soft-delete 상태 잔존 | `az keyvault purge --name <kv-name>` |
| AKS 버전 미지원 | 리전별 가용 버전 상이 | `az aks get-versions --location koreacentral` 확인 |
| VM 할당량 초과 | 구독별 vCPU 할당량 제한 | `az vm list-usage --location koreacentral -o table` 확인 후 할당량 증가 요청 |
| Private Cluster API 접근 불가 | Jump VM 또는 VPN 경유 필요 | Azure Bastion → Jump VM으로 접속 후 kubectl 사용 |
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
