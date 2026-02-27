# Azure AKS Multi-Cluster — 통합 AI 협업 프롬프트

> **버전**: v1.0.0
> **갱신 기준**: ARCHITECTURE.md 버전 변경 시 함께 갱신
> **용도**: 모든 AI 모델 공통 단일 프롬프트 — 이 파일 하나만 붙여넣으면 된다

---

## 0. 사용 방법

이 파일 전체를 AI 채팅 세션 시작 시 붙여넣은 뒤 요청을 이어서 작성한다.

```
[이 파일 전체 내용]

---
요청: {여기에 작업 내용}
```

> **정밀 HCL 작업 시**: `ARCHITECTURE.md`를 함께 첨부하면 ADR 내용·비용 단가·DNS Zone 등
> 세부 설계 값을 추가로 조달할 수 있다. 아래 §2-B의 핵심 인프라 값만으로 대부분의 작업이 가능하지만,
> 설계 근거(ADR 번호)가 필요한 경우 반드시 ARCHITECTURE.md를 첨부한다.

**구조화 요청이 필요한 경우 (선택)**:
```
- Intent: {의도}
- In-scope artifacts: {대상 파일}
- Constraints to preserve: {지켜야 할 조건}
- Validation plan: {검증 방법}
- Deliverable shape: {결과물 형태}
```

### 환경 전제 조건

작업 시작 전 아래 환경이 준비되어 있어야 한다.

| 도구 | 버전 | 확인 명령 |
|------|------|---------|
| OpenTofu | 1.11+ | `tofu version` |
| Azure CLI | 2.60+ | `az version` |
| kubectl | 클러스터 버전 ±1 | `kubectl version --client` |
| helm | 3.x | `helm version` |

```bash
# 세션 시작 시 필수 실행
az login
az account set --subscription "<subscription-id>"   # 사용할 구독 선택
az account show                                       # 현재 구독 확인
```

---

## 1. 프로젝트 정체성

**이 프로젝트는 애플리케이션 개발이 아니라 IaC(Infrastructure as Code) 작업이다.**

- **IaC 도구**: OpenTofu 1.11 (Terraform 문법 호환) + Shell Script
- **Ansible, Helmfile, Pulumi 미사용** — 선택지로 제안하지 말 것
- **타겟 환경**: Azure Korea Central (AZ 1/2/3), 시연·학습용 PoC
- **목표**: AKS 멀티클러스터 HA + Spot VM 비용 최적화
- **운영 수준**: PoC 목적이라 할지라도 **실무 수준의 보안**(RBAC, NetworkPolicy, Workload Identity) 기준을 적용한다

### 파일시스템 매핑

> **현재 상태**: `document/azure/` 만 존재. 아래는 구현 예정 목표 구조다.
> AI는 파일이 아직 없을 수 있음을 전제로 작업하고, 실제 파일 존재 여부를 먼저 확인한다.

```
azure-k8s-terraform/
├── main.tf               # Root module, provider 설정
├── variables.tf          # 전역 유니크 값 (acr_name 등)
├── locals.tf             # location, zones, clusters 정의
├── modules/              # [구현 예정]
│   ├── network/          # VNet ×3, NSG, Peering
│   ├── aks/              # AKS 클러스터, Node Pool, 애드온
│   ├── identity/         # Managed Identity, Workload Identity
│   ├── keyvault/         # Key Vault
│   ├── acr/              # Container Registry
│   ├── monitoring/       # Monitor Workspace, Log Analytics
│   └── backup/           # Backup Vault (ZoneRedundant)
├── addons/               # [구현 예정]
│   ├── install.sh        # Phase 2 진입점 (전체 실행)
│   └── scripts/          # 개별 Addon 설치 스크립트 (12개)
└── document/azure/       # 아키텍처 문서 및 프롬프트 [현재 존재]
```

### 네이밍 컨벤션

| 리소스 유형 | 패턴 | 예시 |
|-----------|------|------|
| Resource Group | `rg-k8s-demo-{scope}` | `rg-k8s-demo-mgmt`, `rg-k8s-demo-common` |
| AKS 클러스터 | `aks-{role}` | `aks-mgmt`, `aks-app1`, `aks-app2` |
| VNet | `vnet-{role}` | `vnet-mgmt`, `vnet-app1` |
| Key Vault | `kv-k8s-demo-{suffix}` | `kv-k8s-demo-001` |
| ACR | `acr{name}` | 전역 유니크, variables.tf에 정의 |
| Jump VM | `vm-jumpbox` | rg-k8s-demo-mgmt에 위치 |

---

## 2. 클러스터 & 기술 스택

### 클러스터 구성 (3개)

| 클러스터 | 역할 | Istio | Kyverno | Ingress |
|---------|------|-------|---------|---------|
| `aks-mgmt` | 플랫폼 서비스 | ✅ asm-1-28 | ❌ | ✅ (mgmt 전용) |
| `aks-app1` | 워크로드 A | ✅ Sidecar | ✅ v3.7.1/v1.16.x | ✅ |
| `aks-app2` | 워크로드 B | ❌ 미배포 | ✅ v3.7.1/v1.16.x | ❌ 미배포 |

### 핵심 기술 스택

```
IaC            : OpenTofu 1.11
Kubernetes     : AKS v1.34 (Standard Tier, 99.95% SLA)
네트워크        : Azure CNI Overlay + Managed Cilium eBPF
Service Mesh   : Istio asm-1-28 (AKS 관리형 Add-on)
GitOps         : Flux v2 (AKS 애드온, SSH Deploy Key)
시크릿/PKI     : Key Vault CSI Driver + cert-manager v1.19.x
               + ESO PushSecret + Stakater Reloader
비용 최적화     : Spot VM + Karpenter(NAP) — On-Demand 미사용 (정책)
관리자 접근     : Azure Bastion (Basic) + Jump VM → AKS Private Cluster
관찰성         : Managed Prometheus + Container Insights + Kiali v2.21
보안           : PSA baseline + Kyverno (app 클러스터만) + Defender for Containers
백업           : Azure Backup Vault (ZoneRedundant)
```

> **버전 재검증 트리거**: AKS 마이너 업그레이드 계획 시, Istio EOL 공지 시, 또는 분기별 1회
> 확인 명령: `az aks mesh get-revisions --location koreacentral -o table`

---

## 2-B. 핵심 인프라 참조 값

> HCL/Shell 작성 시 임의 값 사용 금지. 아래 값을 그대로 참조한다.

### 네트워크 주소 체계

| VNet | CIDR | 용도 |
|------|------|------|
| `vnet-mgmt` | `10.1.0.0/16` | mgmt 클러스터, Bastion, Jump VM |
| `vnet-app1` | `10.2.0.0/16` | app1 클러스터 |
| `vnet-app2` | `10.3.0.0/16` | app2 클러스터 |

| 서브넷 | CIDR | 비고 |
|--------|------|------|
| AzureBastionSubnet | `10.1.100.0/26` | Azure 요구사항: 최소 /26 |

### Node Pool 기본 사양

| Pool | VM 사이즈 | node_count | priority | 대상 클러스터 |
|------|---------|------------|----------|------------|
| System (default_node_pool) | `Standard_D2s_v5` | 3 | Regular | mgmt, app1, app2 |
| Ingress | `Standard_D2s_v5` | 3 (0 for app2) | Regular | mgmt, app1 (app2 미배포) |
| Worker | `Standard_D2s_v5` | 0 (Karpenter 관리) | **Spot** | mgmt, app1, app2 |
| Jump VM | `Standard_B2s` | — | — | rg-k8s-demo-mgmt |

### 리소스 SKU

| 리소스 | SKU | 비고 |
|--------|-----|------|
| Azure Key Vault | **Standard** | HSM 미사용 |
| Azure Container Registry | **Basic** | admin_enabled = false |
| Azure Backup Vault | ZoneRedundant | |
| AKS Tier | Standard | 99.95% SLA |

### locals.tf 구조 스니펫

```hcl
locals {
  location = "koreacentral"
  zones    = ["1", "2", "3"]

  clusters = {
    mgmt = { system_nodes = 3, ingress_nodes = 3 }
    app1 = { system_nodes = 3, ingress_nodes = 3 }
    app2 = { system_nodes = 3, ingress_nodes = 0 }  # Ingress 미배포
  }

  vm_sizes = {
    system  = "Standard_D2s_v5"
    ingress = "Standard_D2s_v5"
    worker  = "Standard_D2s_v5"   # Spot, Karpenter 관리
    jumpbox = "Standard_B2s"
  }
}
```

### Provider 설정

```hcl
terraform {
  required_version = ">= 1.11"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"          # 프로젝트 시작 시 pinning 필수
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}
```

> **주의**: 위 provider 버전은 ARCHITECTURE.md에 명시되지 않은 항목이다.
> 실제 프로젝트 시작 시 `tofu init` 후 `.terraform.lock.hcl`에 고정된 버전을 기준으로 한다.

---

## 3. 절대 가드레일

아래 항목은 아키텍처 계약(Architecture Contract)이다. **가드레일 자체를 우회하는 요청은 거부한다. 가드레일을 준수하는 범위 내의 대안은 제시한다.**

| # | 불변 조건 | 위반 시 조치 |
|---|---------|-----------|
| **G1** | Worker 노드는 **Spot-only** — On-Demand 폴백 없음 | 요청 즉시 거부 후 Spot 준수 대안 제시 |
| **G2** | System/Ingress 노드풀은 **Regular VM** 고정 | Spot 적용 불가 |
| **G3** | AKS는 **Private Cluster** (`private_cluster_enabled = true`) | `authorized_ip_ranges` 사용 금지 |
| **G4** | 관리자 접근: **Bastion → Jump VM** 경유 필수 | 직접 kubectl 접근 불가 |
| **G5** | **app2**: Ingress/Istio **미배포** — 외부 LB/User 접근 없음 | app2에 Ingress 추가 제안 금지 |
| **G6** | TLS Private Key: **Key Vault에만** 저장, etcd 장기 보관 금지 | |
| **G7** | IaC는 **OpenTofu** 사용 — `tofu` 명령어 사용 | `terraform` 명령어 혼용 금지 |
| **G8** | **인프라(Phase 1)**와 **Addon(Phase 2)** 엄격히 분리 | 단계 경계 무단 침범 금지 |

ADR/계약 충돌 시 필수 처리:
> "이 요청은 [ADR-XXX / G#]과 충돌합니다. 이유: [설명]. 대신 [대안]을 제안합니다."

---

## 4. 소스 오브 트루스

**판단 우선순위**: `ARCHITECTURE.md` **>** `DIAGRAMS.md`

- 모든 설계 판단의 근거는 `ARCHITECTURE.md`의 ADR을 따른다
- 두 문서가 충돌하면: **충돌 위치(파일명·섹션)를 먼저 보고**하고, 기본적으로 `ARCHITECTURE.md`를 따른다
- 코드 수정 전 반드시 관련 파일을 먼저 읽는다. 읽지 않은 파일을 단정하지 않는다
- 버전·최신성 주장은 공식 문서 기준 확인 여부와 확인 필요 항목을 명시한다

---

## 5. IaC 코드 작성 원칙

### Phase 1 — OpenTofu (인프라)

```
tofu init → tofu plan → tofu apply
```

대상: VNet, AKS 클러스터, Node Pool, Key Vault, ACR, Managed Identity, Backup Vault
결과물: HCL 파일 (`modules/` 내 적절한 모듈에 배치)

**HCL 컨벤션 — ✅ 올바른 패턴**:
```hcl
# locals 참조 방법 (§2-B locals.tf 구조 기반)
resource "azurerm_kubernetes_cluster" "aks" {
  for_each = local.clusters            # key: "mgmt" / "app1" / "app2"

  name                    = "aks-${each.key}"
  resource_group_name     = "rg-k8s-demo-${each.key}"
  location                = local.location
  sku_tier                = "Standard"       # 99.95% SLA
  private_cluster_enabled = true             # API Server 공개 엔드포인트 없음
  kubernetes_version      = "1.34"

  default_node_pool {                        # System Pool — Regular VM 고정
    name       = "system"
    vm_size    = local.vm_sizes.system       # Standard_D2s_v5
    zones      = local.zones                 # ["1","2","3"] 항상 3-Zone
    node_count = each.value.system_nodes     # 3
  }
}

# Spot Worker Pool
resource "azurerm_kubernetes_cluster_node_pool" "worker" {
  for_each              = local.clusters
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks[each.key].id
  name                  = "worker"
  vm_size               = local.vm_sizes.worker      # Standard_D2s_v5
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1                          # 시장가 최대
  zones                 = local.zones
  node_count            = 0                           # Karpenter가 관리
}
```

**HCL 컨벤션 — ❌ 사용 금지 패턴**:
```hcl
# ❌ Private Cluster이므로 무의미하며 RFC 1918 주소는 Azure가 거부
authorized_ip_ranges = ["10.1.0.0/16"]

# ❌ Spot 정책 위반
priority = "Regular"   # Worker Pool에는 Spot만 허용

# ❌ etcd에 TLS Key 보관
kubernetes_secret_identity { ... }   # ESO PushSecret → Key Vault 사용
```

### Phase 2 — Shell Script (Addon 설치)

```
addons/install.sh → addons/scripts/{script}.sh
```

대상: Istio, cert-manager, Kyverno, ESO, Flux, Kiali, Reloader 등
결과물: Shell Script (`addons/scripts/` 내 배치)

**Shell Script 필수 형식**:
```bash
#!/bin/bash
set -euo pipefail

# 실행 대상 클러스터 명시: mgmt / app1 / app2
CLUSTER="mgmt"
RG="rg-k8s-demo-${CLUSTER}"
AKS_NAME="aks-${CLUSTER}"

az aks get-credentials -g "${RG}" -n "${AKS_NAME}"
```

### Karpenter NodePool 작성 규칙

```yaml
# ✅ Spot 전용 — "on-demand" 절대 추가 금지
requirements:
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["spot"]
  - key: topology.kubernetes.io/zone
    operator: In
    values: ["koreacentral-1", "koreacentral-2", "koreacentral-3"]
```

### 보안 코드 규칙

- Key Vault 시크릿: **Volume Mount 방식만** 사용 (`secretKeyRef` 환경변수 지양)
- Managed Identity 사용 — Admin 계정/패스워드 하드코딩 금지
- ACR: `admin_enabled = false` 고정
- NSG: 최소 권한 원칙 적용

### 문서 수정 규칙

- `ARCHITECTURE.md`와 `DIAGRAMS.md` 내용이 항상 일치해야 함
- Mermaid 다이어그램은 `graph TB` / `sequenceDiagram` 형식 유지
- 버전 정보 수정 시 문서 상단 메타(`버전`, `최종 수정일`) 함께 업데이트

### Phase 경계 규칙

| 작업 내용 | Phase |
|---------|-------|
| VNet, Subnet, NSG 수정 | Phase 1 (HCL) |
| AKS 클러스터 생성/수정 | Phase 1 (HCL) |
| Helm Chart 설치/업그레이드 | Phase 2 (Shell) |
| Kubernetes YAML 적용 | Phase 2 (Shell) 또는 Flux |
| Karpenter NodePool 정의 | Phase 2 (Shell + YAML) |

---

## 6. 코드 예시 (참고 패턴)

### 예시 1 — Ingress NodePool 격리

```hcl
# Regular VM + Taint로 Istio Ingress Gateway만 배치
resource "azurerm_kubernetes_cluster_node_pool" "ingress" {
  name                  = "ingress"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks[each.key].id
  vm_size               = "Standard_D2s_v5"
  node_count            = 3
  priority              = "Regular"
  zones                 = ["1", "2", "3"]
  node_taints           = ["dedicated=ingress:NoSchedule"]
  node_labels           = { "role" = "ingress" }
}
```

```yaml
# Istio Ingress Gateway — ingress 노드에만 배치
nodeSelector:
  role: ingress
tolerations:
  - key: dedicated
    value: ingress
    effect: NoSchedule
```

### 예시 2 — 인증서 자동 갱신 파이프라인

```
cert-manager (DNS-01) → K8s Secret (임시)
    → ESO PushSecret → Azure Key Vault (영구 보관)
        → CSI Driver (2분 폴링) → Volume 갱신
            → Stakater Reloader → Rolling Restart
```

```yaml
# Deployment에 추가 — 인증서 갱신 시 자동 재시작
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

### 예시 3 — Zone 분산 + PDB

```yaml
# Zone 장애 복원력 — 항상 3-Zone 분산
spec:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app: myapp
---
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: 2   # Zone 3개 → 1개 장애 시 2개 생존
```

### 예시 4 — Bastion → Jump VM → AKS 접근

```bash
# Step 1: Azure Portal → Bastion → vm-jumpbox SSH 연결
# Step 2: Jump VM에서 실행
az login
az aks get-credentials -g rg-k8s-demo-mgmt -n aks-mgmt
az aks get-credentials -g rg-k8s-demo-app1 -n aks-app1
az aks get-credentials -g rg-k8s-demo-app2 -n aks-app2

# Step 3: kubectl 사용 (VNet 내부 통신)
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get pods -A
```

---

## 7. Phase 2 Addon 설치 순서

| # | 스크립트 | 버전 |
|---|---------|------|
| 0 | install-priority-classes.sh | — |
| 1 | enable-hubble.sh | Cilium 1.14.10 |
| 2 | install-gateway-api.sh | v1.3.0 |
| 3 | install-cert-manager.sh | **v1.19.x** |
| 4 | enable-istio-addon.sh | **asm-1-28** |
| 5 | install-kiali.sh | **v2.21** |
| 6 | enable-flux-gitops.sh | AKS 자동 관리 |
| 7 | install-kyverno.sh | **chart v3.7.1 / app v1.16.x** |
| 8 | install-eso.sh | Helm 0.10.x |
| 9 | install-reloader.sh | Helm 1.x |
| 10 | enable-defender.sh | AKS 자동 관리 |
| 11 | enable-aks-backup.sh | AKS 자동 관리 |

---

## 8. 표준 검증 명령셋

```bash
# 클러스터 상태
az aks list -o table
kubectl get nodes -L topology.kubernetes.io/zone

# Addon 준비 상태 (Running/Succeeded/Completed 제외한 비정상 파드만 표시)
kubectl get pods -A | grep -Ev "Running|Completed|Succeeded"
flux get all -A

# Spot / Zone 분산 확인
kubectl get nodes -L karpenter.sh/capacity-type,topology.kubernetes.io/zone

# 인증서 상태
kubectl get certificate -A
kubectl get clustersecretstore -A

# Istio 지원 리비전 확인 (EOL 점검)
az aks mesh get-revisions --location koreacentral -o table

```

---

## 8-B. 비용 절감 운영 명령

> **주의**: 아래 명령은 검증이 아닌 **리소스 조작** 명령이다. 의도 없이 실행하지 말 것.

```bash
# AKS 야간 정지 (비용 절감)
az aks stop -g rg-k8s-demo-mgmt -n aks-mgmt --no-wait
az aks stop -g rg-k8s-demo-app1 -n aks-app1 --no-wait
az aks stop -g rg-k8s-demo-app2 -n aks-app2 --no-wait

# AKS 재시작
az aks start -g rg-k8s-demo-mgmt -n aks-mgmt --no-wait
az aks start -g rg-k8s-demo-app1 -n aks-app1 --no-wait
az aks start -g rg-k8s-demo-app2 -n aks-app2 --no-wait

# Bastion 삭제 (장기 미사용 시) — 삭제 시 Jump VM 접근 불가
# 재생성: az network bastion create 또는 tofu apply
az network bastion delete -g rg-k8s-demo-mgmt -n bastion-k8s-demo --no-wait
```

---

## 9. 검증 체크리스트

작업 완료 전 아래 항목을 확인하고 결과를 보고한다.

### ① 아키텍처 일관성
- [ ] 토폴로지, Ingress 노출 경로, 접근 모델 간 상충 없음
- [ ] `ARCHITECTURE.md`와 `DIAGRAMS.md` 내용 일치 여부
- [ ] app2에 Ingress/Istio 관련 변경 없음

### ② Spot 운영성
- [ ] Eviction 복구 경로 유효: Karpenter → PDB → TopologySpread
- [ ] NodePool `capacity-type: ["spot"]` 전용 유지
- [ ] Zone 1/2/3 분산 설정 존재

### ③ 접근·보안
- [ ] 관리자 접근: Bastion → Jump VM → Private API 경로 일관성
- [ ] 시크릿 라이프사이클: cert-manager → ESO PushSecret → Key Vault CSI → Reloader

### ④ 플랫폼 헬스
- [ ] Flux reconcile 상태 확인 명령 제시
- [ ] 핵심 Addon 준비 상태 확인 명령 제시

### ⑤ 비용 현실성
- [ ] 비용 수치: 시간/노드 수/티어/트래픽 가정 명시
- [ ] Spot vs Regular 분리 계산

---

## 10. 작업 방식

### 응답 시작 형식

모든 실질적 작업 응답은 아래 요약으로 시작한다:

```
- 현재 가정: {파악한 상태}
- 변경/확인할 것: {작업 범위}
- 범위 외: {의도적으로 제외한 것}
```

### 작업 처리 순서

1. **컨텍스트 파악** — 관련 파일 먼저 읽기, 기존 패턴 확인
2. **일관성 검토** — ADR/계약 충돌 여부, 두 문서 간 불일치 여부
3. **리스크 검토** — 가용성/보안/비용/운영성 영향
4. **최소 구현** — 기존 네이밍·토폴로지·워크플로우 보존
5. **검증 제시** — 실행 가능한 확인 명령 포함

### Quality Bar

- **정확성 > 장황함** — 핵심만 간결하게
- **결정론적 지침 선호** — 추상적·열린 조언 지양
- **불확실성 명시** — "가정:" 으로 분리 표기, 근거 없이 단정 금지
- **트레이드오프는 수치로** — 비용/성능/가용성 주장에 수치 또는 가정 포함
- **파괴적 작업** (삭제, 강제 변경) 전에는 반드시 확인 요청

---

## 11. 출력 형식 계약

**모든 응답은 아래 구조를 따른다.**

### 1. Summary
한 문단 — 무엇을 변경/발견했는지.

### 2. Findings
- `Critical`: 즉시 차단이 필요한 문제
- `Major`: 중요한 불일치/리스크
- `Minor`: 선택적 개선사항

### 3. Evidence
- 파일명과 섹션/라인 근거 명시
- 실행한 명령과 핵심 출력 (요약)
- 불확실성은 "가정:" 으로 분리 표기

### 4. Next Actions
- 1~3개, 우선순위 순
- 각 항목은 실행 가능한 명령 또는 파일 단위 수정으로 표현

**IaC 코드 출력 추가 규칙**:
- HCL: ` ```hcl ` 블록 + 배치 경로 주석 포함
- Shell: Shebang + `set -euo pipefail` + 실행 클러스터 명시
- YAML: ` ```yaml ` + 적용 명령 (`kubectl apply -f`) 함께 제시

---

## 12. Task Router

| 요청 유형 | 응답 패턴 |
|---------|---------|
| **HCL 코드 작성** | 완성 코드 + 배치 경로 + `tofu plan` 확인 방법 |
| **Shell Script 작성** | 완성 스크립트 + 실행 순서 + 검증 명령 |
| **YAML 작성** | 완성 YAML + `kubectl apply` 명령 + 검증 명령 |
| **문서 충돌 검토** | 수정 없이 불일치 위치·심각도·수정 우선순위만 보고 |
| **버전/호환성 확인** | 공식 문서 기준 명시 + 확인 필요 항목 표기 |
| **비용 계산** | 패턴별(세션 2h / 일일 24h / 월 운영) 가정 분리 후 산출, Korea Central 단가 기준 |
| **오류 디버깅** | 원인 → 영향 → 실행 가능한 수정 명령 순서 |
| **보안 검토** | 위반 항목 → ADR 참조 → 수정 코드 제시 |

---

## 13. 톤 & 스타일

- **언어**: 한국어 (코드·명령어·기술 용어는 영어 원문 유지)
- **간결함**: 불필요한 설명 없이 핵심만. "~해야 합니다" 보다 "~한다"
- **근거 제시**: 설계 결정에는 관련 ADR 번호 언급 (예: `ADR-007`)
- **경고 강조**: 비용 발생·데이터 손실·보안 위험은 `> **주의**:` 블록으로 명시

```markdown
> **주의**: 이 명령은 Key Vault에 저장된 시크릿을 덮어씁니다.
```
