# Azure Kubernetes 멀티클러스터 아키텍처

> **버전**: 3.2.0
> **Kubernetes**: AKS v1.34
> **최종 수정일**: 2026-02-27
> **환경**: Azure Spot VM + Azure 관리형 서비스 (시연/학습용, Korea Central)

---

## 목차

1. [개요](#1-개요) *(1.4 제약 조건 포함)*
2. [아키텍처 결정 기록 (ADR)](#2-아키텍처-결정-기록-adr)
3. [아키텍처 불변 조건](#3-아키텍처-불변-조건-architecture-contract)
4. [클러스터 토폴로지](#4-클러스터-토폴로지)
5. [네트워크 아키텍처](#5-네트워크-아키텍처) *(5.7 관리자 접근 포함)*
6. [스토리지 아키텍처](#6-스토리지-아키텍처)
7. [보안 아키텍처](#7-보안-아키텍처)
8. [관찰성 아키텍처](#8-관찰성-아키텍처)
9. [GitOps (Flux v2)](#9-gitops-flux-v2)
10. [백업 및 DR](#10-백업-및-dr)
11. [리소스 계획 및 비용](#11-리소스-계획-및-비용)
12. [설치 워크플로우](#12-설치-워크플로우) *(12.1 사전 준비 포함)*
13. [서비스 접근 레퍼런스](#13-서비스-접근-레퍼런스)

---

## 1. 개요

### 1.1 프로젝트 목적

Azure 관리형 서비스를 최대한 활용하여 **Kubernetes 멀티클러스터** 환경을 구축합니다.
Korea Central Availability Zone 분산으로 HA를 시연하고, Spot VM으로 비용을 최소화합니다.

### 1.2 대상 환경 및 SLO

| 항목 | 값 |
|-----|-----|
| **환경 유형** | 시연 / 학습 / PoC |
| **리전** | Korea Central (서울) — AZ 1 / 2 / 3 |
| **가용성 목표** | 99.95% Control Plane SLA (Standard Tier + AZ) |
| **RTO** | 30분 (AKS 재생성 기준) |
| **RPO** | 24시간 (일일 백업 기준) |

> Spot VM(Worker Pool) Eviction은 허용. Ingress/System Pool은 Regular VM으로 안정성 확보.

### 1.3 기술 스택

| 영역 | 기술 |
|-----|------|
| **IaC** | OpenTofu 1.11 + Shell Script |
| **리전/가용성** | Korea Central — AZ Zone 1/2/3, AKS Standard Tier |
| **컴퓨팅** | AKS Managed (v1.34), Spot VM, Node Auto-Provisioning (Karpenter) |
| **네트워크** | Azure CNI Overlay + Managed Cilium + Azure LB (Zone-redundant) |
| **Service Mesh** | AKS Istio Add-on asm-1-28 (관리형) |
| **GitOps** | AKS GitOps (Flux v2) |
| **시크릿/PKI** | Azure Key Vault + Key Vault CSI Driver + cert-manager v1.19.x + External Secrets Operator (PushSecret) + Stakater Reloader |
| **정책** | Pod Security Admission (baseline) + Kyverno Helm chart v3.7.1 / App v1.16.x (app 클러스터) |
| **관찰성** | Azure Managed Prometheus (DCR) + Managed Grafana + Container Insights + Application Insights + OTel Collector + Cilium Hubble + Tetragon + Kiali v2.21 + VPA + Alert Rules + Diagnostic Settings + NSG Flow Logs + Activity Log→LAW |
| **보안** | Microsoft Defender for Containers + Cilium Tetragon (eBPF 런타임) + AKS RBAC + Workload Identity + Azure Sentinel (선택) |
| **AI/ML** | — (GPU 쿼터 확보 후 KAITO 추가 가능) |
| **백업** | Azure Backup for AKS (AKS Backup Extension, GA 2025.02) |
| **이미지 레지스트리** | Azure Container Registry (Basic SKU) |
| **관리자 접근** | Azure Bastion + Jump VM (AKS Private Cluster, VNet 내부 전용) |

### 1.4 제약 조건

- Ansible 미사용 (Shell Script로 대체)
- Helmfile 미사용 (Helm CLI 직접 사용)
- AKS Standard Tier (AZ HA 시연 목적, $0.10/cluster/h, 99.95% Control Plane SLA)
- AKS Istio Add-on: **asm-1-28** (v1.34 지원 최신, EOL Aug 2026)
- Gateway API: AKS Istio Add-on Preview (GA 일정은 AKS release notes/release status 기준 추적) → 현재 classic API 사용
- Azure Key Vault Standard SKU (Premium/HSM 미사용)
- ACR Basic SKU (SKU 업그레이드 없이 Zone-redundant 자동 적용)
- Karpenter NodePool `limits` 설정으로 자동 확장 상한 제한 필요
- Spot VM Eviction 시 Karpenter가 동일 또는 다른 Zone에서 자동 재생성

---

## 2. 아키텍처 결정 기록 (ADR)

| ADR | 상태 | 결정 요약 |
|-----|------|----------|
| **ADR-001** | Accepted | 멀티클러스터 (mgmt/app1/app2) — 클러스터 간 독립성 보장 |
| **ADR-002** | Accepted | AKS Standard Tier + Zone 분산 (99.95% SLA) |
| **ADR-003** | Accepted | Kyverno — app 클러스터 전용 Enforce 모드 (mgmt 제외) |
| **ADR-004** | Accepted | Key Vault CSI Driver (AKS 관리형 애드온) |
| **ADR-005** | Accepted | Azure CNI Overlay + Managed Cilium eBPF 데이터플레인 |
| **ADR-006** | Accepted | Azure Managed Prometheus + Container Insights (관리형 관찰성) |
| **ADR-007** | Accepted | Spot VM + Karpenter(NAP) — On-Demand 미사용, 3-Zone 분산 |
| **ADR-008** | Accepted | OpenTofu (Terraform 호환, 오픈소스 IaC) |
| **ADR-009** | Accepted | 인프라(tofu apply) + Addon(install.sh) 2단계 분리 |
| **ADR-010** | Accepted | Log Analytics + Application Insights (로그/트레이스) |
| **ADR-011** | Accepted | Ingress Node Pool Regular VM 고정 (Spot Eviction 방지) |
| **ADR-012** | Accepted | Budget Alert $250/월 + AKS Stop/Start 야간 자동화 |
| **ADR-013** | Accepted | Azure Backup Vault (ZoneRedundant) — AKS Backup 스냅샷 |
| **ADR-014** | Accepted | AKS GitOps 애드온 (Flux v2) — SSH Deploy Key 인증 |
| **ADR-015** | Accepted | Korea Central — AZ 간 트래픽 무료 (2024.06~ Microsoft 정책) |
| **ADR-016** | Accepted | Egress: loadBalancer SNAT (NAT Gateway 미적용, 시연 목적) |
| **ADR-017** | Accepted | cert-manager v1.19.x: Let's Encrypt + DNS-01 챌린지 (Azure DNS 연동) |
| **ADR-018** | Accepted | ACR Basic SKU, Kubelet Identity로 AcrPull 연동 |
| **ADR-019** | Accepted | External Secrets Operator PushSecret — cert-manager 발급 인증서를 Key Vault로 동기화, Private Key etcd 탈출 |
| **ADR-020** | Accepted | Stakater Reloader — Key Vault CSI Auto-rotation 갱신 감지 시 연관 Pod 자동 롤링 재시작 |
| **ADR-021** | Accepted | Azure Bastion + Jump VM — 관리자 kubectl 접근을 VNet 내부로 제한, AKS Private Cluster (공개 엔드포인트 없음, VNet 내부 전용) |

---

## 3. 아키텍처 불변 조건 (Architecture Contract)

> 구현이 변경되더라도 반드시 유지해야 하는 아키텍처 보장 사항

| # | 불변 조건 | 근거 ADR |
|---|----------|----------|
| **C1** | mgmt 클러스터 장애 시에도 app 클러스터 워크로드는 독립 실행 지속 | ADR-001 |
| **C2** | 관찰성 데이터(메트릭/로그/트레이스)는 Azure Monitor에 저장 → 클러스터 장애 시에도 보존 | ADR-006, ADR-010 |
| **C3** | Key Vault CSI Driver는 마운트 시점에 시크릿 로드, Pod 재시작 전까지 캐시 유지 | ADR-004 |
| **C4** | Kyverno는 app 클러스터에만 Enforce 모드 배치 (mgmt 제외) | ADR-003 |
| **C5** | Spot Eviction 시 Karpenter가 워크로드 자동 재스케줄링 (PDB + Topology Spread) | ADR-007 |
| **C6** | System Node Pool과 Ingress Node Pool은 Regular VM 유지 (Spot 미적용) | ADR-007, ADR-011 |
| **C7** | IaC는 OpenTofu 사용, Terraform 문법 호환성 유지 | ADR-008 |
| **C8** | 인프라(tofu apply)와 Addon 설치(addons/install.sh)는 2단계 분리 | ADR-009 |
| **C9** | 백업은 Azure Backup Vault(ZoneRedundant)에 저장 (클러스터 독립적) | ADR-013 |
| **C10** | 월 비용 Budget Alert($250) + AKS Stop/Start 자동화 설정 | ADR-012 |
| **C11** | 모든 노드풀은 Korea Central Zone 1/2/3에 분산 — 단일 Zone 장애 시 나머지 Zone에서 서비스 지속 | ADR-007 |
| **C12** | Flux v2는 SSH Deploy Key(K8s Secret)로 Git 인증 — Federated Token 미사용 | ADR-014 |
| **C13** | TLS 인증서 Private Key는 Azure Key Vault에만 저장 — etcd(K8s Secret)에 장기 보관 금지 (ESO PushSecret 동기화 후 K8s Secret 의존 제거) | ADR-019 |
| **C14** | Key Vault 시크릿/인증서 갱신 시 Stakater Reloader가 자동 Rolling Restart — 수동 개입 없는 무인 갱신 보장 | ADR-020 |
| **C15** | AKS Private Cluster — API Server 공개 엔드포인트 없음, 외부 직접 접근 불가, kubectl은 Bastion → Jump VM 경유 필수 | ADR-021 |

---

## 4. 클러스터 토폴로지

### 4.1 클러스터 역할

| 클러스터 | 역할 | 클러스터 내 컴포넌트 |
|---------|------|-------------------|
| **mgmt** | 플랫폼 서비스 | Istio asm-1-28 (AKS Add-on), Kiali v2.21, cert-manager v1.19.x, Flux v2 |
| **app1** | 워크로드 A | 애플리케이션, Kyverno Helm chart v3.7.1 / App v1.16.x, Istio asm-1-28 Sidecar, Flux v2 |
| **app2** | 워크로드 B | 애플리케이션, Kyverno Helm chart v3.7.1 / App v1.16.x, Flux v2 *(Istio 선택적: L7/mTLS 필요 시)* |

**Azure 관리형 (전 클러스터 공통)**:

| 서비스 | 유형 | 버전/비용 |
|-------|------|---------|
| Managed Cilium | AKS 네트워크 데이터플레인 | v1.14.10, 무료 |
| Managed Prometheus | Azure Monitor Workspace | 자동 관리, ~$1-5/월 |
| Container Insights | AKS 애드온 (DaemonSet) | 자동 관리, 무료(5GB) |
| Key Vault CSI Driver | AKS 애드온 | 자동 관리, 무료 |
| Defender for Containers | Azure Defender 플랜 | 자동 관리, ~$6.87/vCore/월 |
| AKS Backup | Azure Backup Extension | 자동 관리 |
| Karpenter (NAP) | AKS Node Auto-Provisioning | v1.6.5-aks, 무료 |
| Flux v2 | AKS GitOps 애드온 | 자동 관리, 무료 |

### 4.2 AKS 클러스터 스펙

> **AKS Tier**: Standard ($0.10/cluster/h, 99.95% Control Plane SLA)
> **리전**: Korea Central — Zone 1, 2, 3 분산 (Cross-AZ 트래픽 무료)

| 클러스터 | Node Pool | VM Size | 노드 수 | Priority | AZ | 비고 |
|---------|-----------|---------|--------|----------|----|------|
| mgmt | system | Standard_D2s_v5 | **3** | Regular | 1,2,3 | Zone당 1노드 |
| mgmt | ingress | Standard_D2s_v5 | **3** | Regular | 1,2,3 | Istio Ingress Gateway 전용 |
| mgmt | worker | Standard_D2s_v5 | 0+ | **Spot** | 1,2,3 | Kiali, cert-manager (Karpenter) |
| app1 | system | Standard_D2s_v5 | **3** | Regular | 1,2,3 | Zone당 1노드 |
| app1 | ingress | Standard_D2s_v5 | **3** | Regular | 1,2,3 | Istio Ingress Gateway 전용 |
| app1 | worker | Standard_D2s_v5 | 0+ | **Spot** | 1,2,3 | 앱 워크로드 (Karpenter) |
| app2 | system | Standard_D2s_v5 | **3** | Regular | 1,2,3 | Zone당 1노드 |
| app2 | worker | Standard_D2s_v5 | 0+ | **Spot** | 1,2,3 | 앱 워크로드 (Karpenter) |

> Standard_D2s_v5 = 2 vCPU / 8GB RAM

**ingress 노드풀 격리 (Terraform)**:

```hcl
resource "azurerm_kubernetes_cluster_node_pool" "ingress" {
  name       = "ingress"
  vm_size    = "Standard_D2s_v5"
  node_count = 3                          # 1 per zone
  priority   = "Regular"
  zones      = ["1", "2", "3"]

  node_taints = ["dedicated=ingress:NoSchedule"]
  node_labels = { "role" = "ingress" }
}
```

**Istio Ingress Gateway — ingress 노드 배치**:

```yaml
nodeSelector:
  role: ingress
tolerations:
  - key: dedicated
    value: ingress
    effect: NoSchedule
```

> **ingress Regular 이유**: Spot Eviction 시 Ingress Gateway 단절 → 외부 트래픽 전체 영향.
> Regular VM으로 Eviction 없이 안정적 트래픽 처리 보장.

**Korea Central Zone 배치도**:

```
                   Zone 1 (서울)     Zone 2 (서울)     Zone 3 (서울)
                  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
mgmt              │ system × 1  │   │ system × 1  │   │ system × 1  │  ← Regular
                  │ ingress × 1 │   │ ingress × 1 │   │ ingress × 1 │  ← Regular
                  │  (worker)   │   │  (worker)   │   │  (worker)   │  ← Spot/Karpenter
                  └─────────────┘   └─────────────┘   └─────────────┘

                  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
app1              │ system × 1  │   │ system × 1  │   │ system × 1  │  ← Regular
                  │ ingress × 1 │   │ ingress × 1 │   │ ingress × 1 │  ← Regular
                  │  (worker)   │   │  (worker)   │   │  (worker)   │  ← Spot/Karpenter
                  └─────────────┘   └─────────────┘   └─────────────┘

                  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
app2              │ system × 1  │   │ system × 1  │   │ system × 1  │  ← Regular
                  │  (worker)   │   │  (worker)   │   │  (worker)   │  ← Spot/Karpenter
                  └─────────────┘   └─────────────┘   └─────────────┘
```

> Azure Zone 번호는 논리 번호 — 구독마다 물리 위치 매핑이 다를 수 있음.

**Zone 장애 시 동작**:

| 구성 요소 | Zone 1 장애 시 |
|---------|--------------|
| Control Plane (Standard Tier) | Zone 2, 3으로 자동 failover |
| System Pool (3 nodes) | 2 nodes 생존, 클러스터 운영 지속 |
| Ingress Pool (3 nodes) | 2 Gateway 생존, 외부 트래픽 계속 처리 |
| Worker Pool (Spot + Karpenter) | Zone 2, 3에 새 노드 자동 프로비저닝 |

**Zone 장애 시연**:

```bash
# Zone 1 장애 시뮬레이션
kubectl cordon $(kubectl get nodes -l topology.kubernetes.io/zone=koreacentral-1 -o name)
kubectl get nodes -L topology.kubernetes.io/zone -w

# 복구
kubectl uncordon $(kubectl get nodes -l topology.kubernetes.io/zone=koreacentral-1 -o name)
```

### 4.3 Node Auto-Provisioning (Karpenter)

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
spec:
  template:
    spec:
      requirements:
        - key: karpenter.azure.com/sku-family
          operator: In
          values: ["D"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]                    # Spot 전용 — On-Demand 미사용 (정책)
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["koreacentral-1", "koreacentral-2", "koreacentral-3"]
  limits:
    cpu: "20"
    memory: "40Gi"                            # D2s_v5 기준 약 10노드 상한
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

> **Spot 전용 정책**: On-Demand 폴백 미사용. 특정 Zone Spot 용량 부족 시 다른 Zone으로만 폴백.
> 3개 Zone 모두 Spot 용량 없을 경우 워크로드는 Pending 유지 — 이를 의식적으로 수용하는 설계.
> Korea Central AZ 간 트래픽 **무료** (2024.06~ Microsoft 정책).
>
> **[향후 개선]** Karpenter `karpenter.sh/v1` API 안정화에 따라 Azure 전용 속성 활용 강화 검토.
> 예: `capacity-reservation-id` 연동, Zone별 Spot 가중치 우선순위(priority) 정교화로 특정 Zone 용량 부족 상황 대응 개선.

### 4.4 네트워크 구성

> 클러스터마다 **독립 VNet**을 생성하고 **VNet Peering**으로 상호 연결한다.

| 리소스 | CIDR / 설정 |
|-------|------------|
| **mgmt VNet** | 10.1.0.0/16 |
| **app1 VNet** | 10.2.0.0/16 |
| **app2 VNet** | 10.3.0.0/16 |
| **전체 주소 공간** | 10.0.0.0/8 |
| **VNet Peering** | mgmt ↔ app1, mgmt ↔ app2, app1 ↔ app2 |
| **Pod CIDR (Overlay)** | 클러스터별 자동 할당 |
| **Service CIDR** | 클러스터별 자동 할당 |

### 4.5 Resource Group 구성

| Resource Group | 포함 리소스 |
|---------------|-----------|
| **rg-k8s-demo-common** | VNet(×3), NSG(×3), Key Vault, ACR, DNS Zone, Azure Monitor Workspace, Log Analytics Workspace, Backup Vault |
| **rg-k8s-demo-mgmt** | AKS mgmt, Managed Identity, **Azure Bastion**, **Jump VM** (B2s, private IP) |
| **rg-k8s-demo-app1** | AKS app1, Managed Identity |
| **rg-k8s-demo-app2** | AKS app2, Managed Identity |

---

## 5. 네트워크 아키텍처

### 5.1 Azure CNI Overlay + Managed Cilium

| 설정 | 값 | 설명 |
|-----|----|----|
| `networkPlugin` | `azure` | Azure CNI |
| `networkPluginMode` | `overlay` | Pod에 VNet IP 미할당 (IP 절약) |
| `networkDataplane` | `cilium` | Managed Cilium eBPF 데이터플레인 |
| kube-proxy | 자동 대체 | eBPF 기반 서비스 라우팅 |
| Network Policy | Cilium | L3/L4 정책 적용 |
| Hubble | 수동 활성화 | 네트워크 플로우 관찰성 (무료) |

```hcl
resource "azurerm_kubernetes_cluster" "aks" {
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
  }
}
```

#### ADR-005 상세: Managed Cilium

| 항목 | 설정 |
|-----|------|
| 데이터플레인 | Cilium eBPF v1.14.10 (kube-proxy 대비 30% 지연 감소) |
| 업그레이드 | AKS 버전과 동기화, 자동 관리 |
| Network Policy | Cilium 네이티브 |
| Hubble | 수동 활성화 (무료) |
| 비용 | **무료** (ACNS 고급 기능은 유료) |

### 5.2 Azure Load Balancer

| 항목 | 설정 |
|-----|------|
| SKU | Standard |
| Zone 분산 | Zone-redundant (자동) |
| Type | Public (시연용) |
| Outbound Type | `loadBalancer` |
| 역할 | `Service type=LoadBalancer` 자동 프로비저닝 |

### 5.3 Gateway API

> **[현재 구현]** Istio `Gateway` + `VirtualService` (classic API) 사용
> **[향후 전환 예정]** Gateway API — AKS Istio Add-on Preview, GA 확정 시 전환 검토 (AKS release notes/release status 기준 추적)
> **[조기 전환 검토]** 2026년 중 Preview 기능이 안정화된 경우 기술 부채 최소화를 위해 Phase 2에서 Gateway API 기본 적용을 검토할 수 있음

- CRD 버전: **v1.3.0** (수동 설치 — `00b-gateway-api.sh`, Istio GA 전환 대비 사전 배포)
- GA 전까지는 Istio classic API 사용 — CRD 설치만 완료하고 실제 Gateway/HTTPRoute 리소스는 미사용

### 5.4 AKS Istio Add-on (asm-1-28)

| 클러스터 | 배포 범위 |
|---------|----------|
| **mgmt** | Istiod (관리형) + Ingress Gateway (ingress 노드풀) |
| **app1** | Istiod (관리형) + Ingress Gateway (ingress 노드풀) + Sidecar Injection (mTLS STRICT) |
| **app2** | **[현재] 미배포** / **[향후/옵션]** L7 트래픽 제어 또는 mTLS 필요 시 도입 |

| 항목 | 설정 |
|-----|------|
| 설치 | `az aks mesh enable --revision asm-1-28` |
| 업그레이드 | Canary 방식 (두 리비전 병행 가능) |
| v1.34 지원 리비전 | asm-1-26, asm-1-27, **asm-1-28** (asm-1-25 이하 EOL) |
| 비용 | **무료** (사이드카 컴퓨팅 리소스만 과금) |

> **EOL 주기 점검 권장**: asm-1-28 EOL 윈도우가 가까워질 수 있으므로 분기별로 아래 명령으로 지원 리비전을 확인하고 업그레이드 시점을 계획할 것.
> ```bash
> az aks mesh get-revisions --location koreacentral -o table
> ```

> **[향후 개선]** Istio **Ambient Mesh (Sidecar-less)** 모드 검토.
> Sidecar 제거 시 노드당 메모리 10~20% 절감 → Spot VM 기반 비용 최적화 아키텍처에 특히 유리.
> AKS Managed Istio의 Ambient 지원 현황은 `az aks mesh get-revisions` 및 AKS release notes에서 추적 필요.

**메쉬 토폴로지 — 독립 메쉬**:

| 항목 | 설정 |
|-----|------|
| 토폴로지 | 클러스터당 독립 메쉬 (Multi-primary 미적용) |
| 클러스터 간 서비스 디스커버리 | 없음 (VNet Peering으로 L3 통신만) |
| mTLS 범위 | 각 클러스터 내부만 |

**Managed Cilium + Istio 역할 분담**:

| 계층 | Managed Cilium | AKS Istio Add-on |
|-----|----------------|-----------------|
| L3/L4 네트워킹 | O | - |
| kube-proxy 대체 | O | - |
| Network Policy | O | - |
| L7 트래픽 제어 (Retry/Timeout/Canary) | - | O |
| mTLS | - | O |
| AuthorizationPolicy | - | O |
| Ingress Gateway | - | O |
| 관찰성 | Hubble | Kiali |

### 5.5 Egress 트래픽 제어 (ADR-016)

| 항목 | 설정 |
|-----|------|
| **Outbound Type** | `loadBalancer` (Azure LB SNAT) |
| **Istio Egress Gateway** | 미사용 |
| **NAT Gateway** | **[현재] 미도입** / **[향후/프로덕션]** 도입 권장 (~$32/월) |

> **SNAT Port Exhaustion 리스크**: Azure LB SNAT은 노드당 기본 1,024개 포트 할당.
> 동일 외부 엔드포인트로의 동시 연결이 1,024개 초과 시 연결 실패 발생.
> 3개 클러스터가 동일 외부 서비스(GitHub, 외부 API 등)를 집중 호출하는 경우 시연 중에도 SNAT 고갈이 발생할 수 있음.
> 단기 대응: `allocatedOutboundPorts` 사전 할당 설정으로 포트 수 증가.
>
> **[향후 재검토]** Azure NAT Gateway 도입 (~$32/월 기준) — 3 클러스터 × 동시 호출 패턴이 증가할 경우 안정성 확보를 위해 우선 검토. Azure NAT Gateway 가격 정책 변경 여부는 공식 Pricing Calculator(Korea Central) 기준 최신 확인 권장.

### 5.6 Cross-Cluster 통신

| 방식 | 구현 |
|-----|------|
| **VNet Peering** | mgmt ↔ app1, mgmt ↔ app2, app1 ↔ app2 |
| **Private Endpoint** | Key Vault (구현 완료) — Azure Monitor Workspace PE는 향후 추가 검토 |
| **AKS API Server** | Private Cluster (`private_cluster_enabled = true`) — 공개 엔드포인트 없음, VNet 내부 DNS 해석, Jump VM 경유 필수 |
| **AKS Private DNS Zone** | 공유 DNS Zone (`privatelink.koreacentral.azmk8s.io`) — 3개 VNet 모두 링크, Jump VM에서 전 클러스터 API Server 접근 가능 |

> **Private DNS Zone 공유**: VNet Peering은 트래픽만 전달하고 DNS 쿼리는 전달하지 않는다.
> AKS Private Cluster의 API Server FQDN 해석을 위해 공유 Private DNS Zone을 생성하고
> 3개 VNet에 VNet Link를 설정한다. Control Plane Identity에 `Private DNS Zone Contributor` 역할을 부여한다.

### 5.7 관리자 접근 아키텍처 (ADR-021)

**접근 흐름**:

```
[관리자 PC]
    │  HTTPS (443)
    ▼
Azure Bastion (PaaS, AzureBastionSubnet)
    │  SSH (프라이빗, 브라우저 기반)
    ▼
Jump VM (Standard_B2s, private IP, mgmt VNet)
    │  kubectl / az CLI
    ▼
AKS API Server (Private Cluster — VNet 내부 DNS 해석, 공개 엔드포인트 없음)
```

| 항목 | 설정 |
|-----|------|
| **Azure Bastion SKU** | Basic (~$0.19/h) — 브라우저 기반 SSH, Jump VM Public IP 불필요 |
| **Jump VM 크기** | Standard_B2s (2vCPU/4GB) — 관리 작업 전용 |
| **Jump VM 위치** | mgmt VNet (10.1.0.0/16), private IP만 할당 |
| **AzureBastionSubnet** | 10.1.100.0/26 (mgmt VNet 내, /26 이상 필수) |
| **AKS API Server** | Private Cluster — 공유 Private DNS Zone (`privatelink.koreacentral.azmk8s.io`), 3개 VNet Link |
| **인증** | Entra ID (Azure Bastion) + SSH Key (Jump VM) |
| **Resource Group** | rg-k8s-demo-mgmt |

**Terraform 핵심 패턴**:

```hcl
# AzureBastionSubnet (이름 고정 필수)
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.common.name
  virtual_network_name = azurerm_virtual_network.mgmt.name
  address_prefixes     = ["10.1.100.0/26"]
}

# Azure Bastion (PaaS)
resource "azurerm_bastion_host" "mgmt" {
  name                = "bastion-k8s-demo"
  resource_group_name = azurerm_resource_group.mgmt.name
  location            = local.location
  sku                 = "Basic"

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# Jump VM (private only)
resource "azurerm_linux_virtual_machine" "jumpvm" {
  name                = "vm-jumpbox"
  resource_group_name = azurerm_resource_group.mgmt.name
  location            = local.location
  size                = "Standard_B2s"

  network_interface_ids = [azurerm_network_interface.jumpvm.id]
  # public_ip 미할당 — Bastion 경유만 허용
}

# AKS Private Cluster — API Server 공개 엔드포인트 비활성화
resource "azurerm_kubernetes_cluster" "aks" {
  private_cluster_enabled = true
  # private DNS zone 자동 생성
  # Jump VM → VNet 내부 private DNS 해석으로 kubectl 접근
  # 외부 인터넷에서 API Server 직접 접근 불가
}
```

> **비용 주의**: Azure Bastion Basic은 AKS Stop 상태에서도 ~$0.19/h 과금.
> 미사용 시 `az network bastion delete`로 삭제 후 필요 시 재생성 권장 (~2분 소요).

### 5.8 DNS 자동화

| 항목 | 설정 |
|-----|------|
| **Azure DNS Zone** | rg-k8s-demo-common에 생성 |
| **external-dns** | **[현재] 미사용** (수동 관리) / **[향후/프로덕션]** Helm 설치 후 자동 등록 권장 |
| **레코드 등록** | Istio Ingress Gateway Public IP를 수동으로 Azure DNS에 등록 |

---

## 6. 스토리지 아키텍처

### 6.1 Kubernetes StorageClass

| StorageClass | Provisioner | SKU | ReclaimPolicy | 용도 |
|-------------|-------------|-----|---------------|------|
| **managed-csi** (기본) | disk.csi.azure.com | Premium_LRS | Delete | 일반 워크로드 (단일 Zone) |
| **managed-csi-zrs** | disk.csi.azure.com | **Premium_ZRS** | Delete | **Zone 장애 시에도 PV 유지** |
| **managed-csi-retain** | disk.csi.azure.com | Premium_LRS | Retain | 상태 유지 필요 시 |
| **azurefile-csi** | file.csi.azure.com | — | Delete | ReadWriteMany 필요 시 |

> Korea Central ZRS 지원: Premium SSD ✅ / Standard SSD ✅ / Ultra Disk ❌ / Premium SSD v2 ❌

**managed-csi-zrs StorageClass**:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-zrs
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_ZRS
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer   # Pod Zone 확정 후 PV 생성 (AZ-aware)
allowVolumeExpansion: true
```

> `WaitForFirstConsumer`: Pod가 특정 Zone에 스케줄된 이후 해당 Zone에 PV 생성.
> `Immediate` 사용 시 PV Zone과 Pod Zone 불일치로 마운트 실패 가능.

**Zone 분산 Pod 배치 — TopologySpreadConstraints**:

```yaml
spec:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app: myapp
```

**Zone 장애 복원력 — PodDisruptionBudget**:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: myapp-pdb
spec:
  minAvailable: 2       # Zone 3개 → 1개 장애 시 2개 생존 보장
  selector:
    matchLabels:
      app: myapp
```

> Azure 관리형 서비스 활용으로 **플랫폼 컴포넌트의 클러스터 내 PV 사용이 없음**.
> PV는 앱 워크로드 요구사항에 따라서만 사용. Zone HA 필요 시 `managed-csi-zrs` 선택.

### 6.2 Azure 관리형 데이터 저장소

| 서비스 | 저장 데이터 | 보존 기간 |
|-------|-----------|----------|
| **Azure Monitor Workspace** | Prometheus 메트릭 | 18개월 (기본 포함) |
| **Log Analytics Workspace** | 컨테이너 로그 | 30일 (기본) ~ 12년 (아카이브) |
| **Application Insights** | 분산 트레이스 | 90일 (기본) |
| **Azure Backup Vault** | AKS 백업 스냅샷 | 7일 (시연 설정) |

---

## 7. 보안 아키텍처

### 7.1 보안 계층

| 계층 | 구현 | 범위 |
|-----|------|------|
| **L1 ID/접근** | Entra ID + AKS RBAC + Managed Identity + Workload Identity | 전 클러스터 |
| **L2 워크로드 정책** | PSA baseline enforce + Kyverno Enforce (app만) | 전 클러스터 |
| **L3 네트워크** | Managed Cilium NetworkPolicy + Azure NSG | 전 클러스터 |
| **L4 시크릿** | Azure Key Vault + CSI Driver + ESO PushSecret (Private Key etcd 미노출) + Stakater Reloader (자동 재시작) | 전 클러스터 |
| **L5 런타임 보안** | Microsoft Defender for Containers (위협 탐지 + 악성코드) + Cilium Tetragon (eBPF 프로세스/파일 추적) | 전 클러스터 |
| **L6 취약점 관리** | Defender for Containers (이미지 CVE 스캔 + 배포 차단) | 전 클러스터 |
| **L7 SIEM/SOAR** | Azure Sentinel (AI 위협 탐지 + Playbook 자동화, 선택적 활성화) | 구독 레벨 |

### 7.2 Microsoft Defender for Containers

| 기능 | 설명 |
|-----|------|
| 런타임 위협 탐지 | 컨테이너 행동 분석 기반 실시간 탐지 |
| 이미지 취약점 스캔 | 레지스트리 + 실행 중 컨테이너 대상 |
| 노드 취약점 평가 | 노드 OS 레벨 스캔 |
| 악성코드 탐지 | 컨테이너 내 악성코드 감지 |
| 배포 차단 (게이팅) | 취약한 이미지 배포 자동 차단 |
| 비용 | ~$6.87/vCore/월 |

### 7.3 Key Vault CSI Driver + ESO + Reloader

```
AKS Cluster
 └─ cert-manager (인증서 발급/갱신)
      └─ K8s Secret (tls.crt, tls.key) — 임시 저장
           └─ ESO PushSecret (즉시 동기화, ADR-019)
                └─ Azure Key Vault ── Private Key 영구 보관 (etcd 미노출)
                     └─ Key Vault CSI Driver (AKS 애드온, 무료)
                          ├─ SecretProviderClass → Volume Mount (etcd 미저장)
                          ├─ Auto-rotation (2분 간격 폴링)
                          └─ Volume 파일 갱신 감지
                               └─ Stakater Reloader (ADR-020)
                                    └─ 연관 Deployment Rolling Restart
                                         └─ Istio Ingress Gateway 무중단 인증서 교체
```

| 컴포넌트 | 역할 | 비용 |
|---------|------|------|
| cert-manager | Let's Encrypt 발급/갱신, DNS-01 챌린지 | 무료 |
| ESO PushSecret | K8s Secret → Key Vault 단방향 동기화 | 무료 |
| Key Vault CSI Driver | Key Vault → Pod Volume 마운트 (AKS 애드온) | 무료 |
| Stakater Reloader | Volume 갱신 감지 → Pod 자동 재시작 | 무료 |

> **시크릿 갱신 주의**: Auto-rotation은 **Volume 파일만 갱신**하며,
> `env.valueFrom.secretKeyRef` 환경 변수는 Pod 재시작 전까지 반영 안 됨.
> Stakater Reloader가 이를 자동 처리 — Annotation 하나로 연동.

```yaml
# Deployment에 Reloader Annotation 추가
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

#### ADR-017 상세: cert-manager 인증서 관리

| 항목 | 설정 |
|-----|------|
| **버전** | v1.19.x (최신 패치 사용 권장 — cert-manager releases 기준) |
| **CA** | Let's Encrypt (Production) |
| **챌린지 방식** | DNS-01 (Azure DNS Zone 연동) |
| **인증** | Workload Identity → Managed Identity → Azure DNS Zone Contributor |
| **발급 대상** | Istio Ingress Gateway TLS 인증서 (`*.example.com`) |
| **갱신** | cert-manager 자동 갱신 (만료 30일 전) |
| **Private Key 보호** | ESO PushSecret으로 Key Vault 동기화 — etcd 미노출 (ADR-019) |
| **Pod 반영** | Key Vault CSI Auto-rotation + Stakater Reloader 자동 재시작 (ADR-020) |

**인증서 자동 갱신 라이프사이클**:

```
[발급]
cert-manager ──DNS-01──▶ Let's Encrypt ──▶ K8s Secret (tls.crt / tls.key)
                                                  │
[동기화]                                  ESO PushSecret (즉시)
                                                  │
                                          Azure Key Vault ◀─── Private Key 영구 보관
                                                  │
[마운트]                            Key Vault CSI Driver (2분 폴링)
                                                  │
                                          Volume 파일 갱신
                                                  │
[재시작]                              Stakater Reloader 감지
                                                  │
                                   Istio Ingress Gateway Rolling Restart
[갱신]
cert-manager ──만료 30일 전──▶ 위 흐름 자동 반복 (무인 자동화)
```

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          azureDNS:
            subscriptionID: <subscription-id>
            resourceGroupName: rg-k8s-demo-common
            hostedZoneName: example.com
            environment: AzurePublicCloud
            managedIdentity:
              clientID: <cert-manager-mi-client-id>
```

> DNS-01 선택 이유: Wildcard 인증서(`*.example.com`) 발급 가능, HTTP-01은 Wildcard 미지원.

### 7.4 Kyverno 정책 (app 클러스터만, Helm chart v3.7.1 / App v1.16.x)

| 정책 | 모드 | 내용 |
|-----|------|------|
| `restrict-image-registries` | Enforce | `acrkdemo.azurecr.io/*`, `docker.io/library/*`, `quay.io/*`, `registry.k8s.io/*` 허용 |
| `require-resource-limits` | Enforce | requests/limits 필수 |
| `disallow-privileged-containers` | Enforce | `privileged: false` 강제 |
| `require-labels` | Audit | app, version 라벨 필수 |
| `generate-pdb` | Generate | replicas > 1인 Deployment에 PDB 자동 생성 (minAvailable: 1) |
| `require-topology-spread` | Audit | replicas > 1인 Deployment에 `topology.kubernetes.io/zone` TopologySpread 강제 |

#### ADR-003 상세: Kyverno 배치 범위

| 클러스터 | Kyverno | 이유 |
|---------|---------|------|
| **mgmt** | 미설치 | 플랫폼/운영자 영역, PSA baseline만 적용 |
| **app1/app2** | Enforce 모드 (Helm chart v3.7.1 / App v1.16.x) | 개발팀 워크로드 정책 강제 |

> **mgmt 클러스터 Kyverno 검토**: 정책 위반 모니터링이 필요한 경우 **Audit 모드**로 설치하여
> 위반 로깅만 수행하는 방안 검토 가능. Enforce 모드는 플랫폼 컴포넌트 배포를 차단할 위험이 있어 권장하지 않음.

### 7.5 Azure Container Registry (ADR-018)

| 항목 | 설정 |
|-----|------|
| **SKU** | Basic (시연 목적, 10GB 포함) |
| **Zone 분산** | 자동 (2024년~ 전 SKU 기본값) |
| **Resource Group** | rg-k8s-demo-common |
| **AKS 연동** | Kubelet Identity에 `AcrPull` 역할 할당 |
| **Admin 계정** | 비활성화 (Managed Identity만 사용) |

> **ACR 이름 전역 유니크 제약**: ACR 이름은 `*.azurecr.io` DNS로 전 세계에서 유일해야 함.
> `variables.tf`에 `acr_name` 변수로 관리하거나 프로젝트명 + 랜덤 suffix 조합 권장.

```hcl
resource "azurerm_container_registry" "acr" {
  name                = var.acr_name        # 전역 유니크 이름 변수로 관리
  resource_group_name = azurerm_resource_group.common.name
  location            = local.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_role_assignment" "aks_acr" {
  for_each             = toset(["mgmt", "app1", "app2"])
  principal_id         = azurerm_kubernetes_cluster.aks[each.key].kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}
```

### 7.6 Managed Identity & Workload Identity

```
AKS Cluster
 └─ User-Assigned Managed Identity (Control Plane)
 └─ User-Assigned Kubelet Identity → ACR (AcrPull)
 └─ Workload Identity Federation
      ├─ cert-manager → Key Vault (인증서) + Azure DNS Zone (DNS-01)
      ├─ Key Vault CSI Driver → Key Vault (시크릿)
      ├─ AKS Backup Extension → Backup Vault
      └─ Container Insights Agent → Azure Monitor Workspace
```

---

## 8. 관찰성 아키텍처

### 8.1 스택 구성

| 영역 | 서비스 | 비용 (시연 규모) |
|-----|-------|----------------|
| **메트릭** | Azure Managed Prometheus → Azure Monitor Workspace | ~$1-5/월 |
| **시각화** | Azure Managed Grafana (Standard SKU, Prometheus 자동 연동) | **무료** (Standard: 첫 인스턴스) |
| **로그** | Container Insights → Log Analytics Workspace | **무료** (5GB/월) |
| **Control Plane 로그** | AKS Diagnostic Settings → LAW (kube-audit-admin 등 7개 카테고리) | LAW 수집량에 포함 |
| **Key Vault 감사** | Key Vault Diagnostic Settings → LAW (AuditEvent) | LAW 수집량에 포함 |
| **Activity Log** | 구독 레벨 Diagnostic Setting → LAW (8개 카테고리, 장기 보존) | LAW 수집량에 포함 |
| **트레이싱** | Application Insights (OpenTelemetry) | **무료** (5GB/월 공유) |
| **분산 트레이싱** | OpenTelemetry Collector → Application Insights (OTLP) | Helm 직접 설치 |
| **네트워크 플로우** | Cilium Hubble (UI + Relay) | **무료** |
| **NSG Flow Log** | Network Watcher Flow Log v2 + Traffic Analytics → LAW (10분 간격) | ~$0.50/NSG/월 |
| **런타임 보안 감시** | Cilium Tetragon (eBPF 프로세스/파일/네트워크 추적) | Helm 직접 설치 |
| **서비스 그래프** | Kiali v2.21 (Helm 설치, mgmt only) | Helm 직접 설치 |
| **Pod 리소스 최적화** | Vertical Pod Autoscaler (recommend-only 모드) | Helm 직접 설치 |
| **알림** | Azure Monitor Alert Rules (CPU/Memory >90%, CrashLoopBackOff KQL) | **무료** (기본 rule 포함) |

#### ADR-006 상세: Azure Managed Prometheus

| 항목 | 설정 |
|-----|------|
| 활성화 | AKS 클러스터 생성 시 `monitor_metrics {}` 원클릭 |
| 데이터 보존 | **18개월** (추가 비용 없이 포함) |
| HA | Azure에서 자동 보장 (Zone-redundant) |
| PromQL | 완전 지원 |
| 비용 (시연 규모) | **~$1-5/월** (ingestion 기준) |

### 8.2 데이터 흐름

```
AKS Cluster (mgmt / app1 / app2)
 ├─ Container Insights Agent (관리형 DaemonSet)
 │    ├─ Prometheus 메트릭 → Azure Monitor Workspace (DCE/DCR)
 │    └─ 컨테이너 로그 → Log Analytics Workspace
 ├─ AKS Diagnostic Setting → LAW (Control Plane 로그 7개 카테고리)
 ├─ Application Insights SDK / OTel → Application Insights (트레이스)
 └─ Cilium Hubble → Hubble UI (네트워크 플로우)

Azure 인프라 레벨
 ├─ Key Vault Diagnostic Setting → LAW (AuditEvent)
 ├─ NSG Flow Logs → Storage Account + Traffic Analytics → LAW
 └─ Activity Log (구독) → LAW (Administrative, Security 등 8개 카테고리)

Azure Monitor (시각화 · 알림)
 ├─ Managed Grafana → Prometheus 대시보드 (자동 연동)
 ├─ Alert Rules → CPU/Memory >90% (Metric), CrashLoopBackOff (KQL)
 ├─ Log Analytics → KQL 쿼리
 ├─ Application Insights → 분산 트레이스 / Application Map
 └─ AKS GitOps → Flux 구성 상태
```

### 8.3 OpenTofu 관찰성 구성

```hcl
# --- modules/monitoring/main.tf ---
resource "azurerm_monitor_workspace" "mon" { ... }           # Managed Prometheus
resource "azurerm_log_analytics_workspace" "law" { ... }     # Container Insights + 로그
resource "azurerm_application_insights" "appi" { ... }       # 분산 트레이싱
resource "azurerm_dashboard_grafana" "grafana" {              # Managed Grafana
  grafana_major_version = "10"
  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.mon.id            # Prometheus 자동 연동
  }
}
resource "azurerm_monitor_diagnostic_setting" "activity_log" { # 구독 Activity Log → LAW
  target_resource_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}"
  # Administrative, Security, Alert, Policy 등 8개 카테고리
}

# --- modules/aks/main.tf ---
resource "azurerm_kubernetes_cluster" "aks" {
  monitor_metrics {}                          # Managed Prometheus
  oms_agent { ... }                           # Container Insights
}

# --- modules/aks/prometheus.tf — DCE/DCR/DCRA 연결 ---
resource "azurerm_monitor_data_collection_endpoint" "prometheus" { ... }
resource "azurerm_monitor_data_collection_rule" "prometheus" { ... }
resource "azurerm_monitor_data_collection_rule_association" "prometheus" { ... }

# --- modules/aks/diagnostics.tf — Control Plane 로그 ---
resource "azurerm_monitor_diagnostic_setting" "aks" {
  for_each = var.clusters
  # kube-apiserver, kube-audit-admin, kube-controller-manager,
  # kube-scheduler, cluster-autoscaler, guard, cloud-controller-manager
}

# --- modules/aks/alerts.tf — 핵심 알림 ---
resource "azurerm_monitor_metric_alert" "cpu_high" { ... }    # CPU > 90%
resource "azurerm_monitor_metric_alert" "memory_high" { ... } # Memory > 90%
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "crashloop" { ... } # CrashLoopBackOff

# --- modules/keyvault/main.tf — Key Vault 감사 로그 ---
resource "azurerm_monitor_diagnostic_setting" "kv" { ... }    # AuditEvent → LAW

# --- flow-logs.tf (root) — NSG Flow Logs + Traffic Analytics ---
resource "azurerm_network_watcher" "nw" { ... }
resource "azurerm_storage_account" "flow_logs" { ... }
resource "azurerm_network_watcher_flow_log" "aks" {
  for_each = local.vnets
  version  = 2
  traffic_analytics { interval_in_minutes = 10 }              # LAW 연동
}
```

### 8.4 장애 시 동작

| 시나리오 | 동작 |
|---------|------|
| **클러스터 장애** | 메트릭/로그가 Azure Monitor에 저장 → 기존 데이터 유실 없음 |
| **Spot Eviction** | 노드 재생성 후 Agent 자동 재배포, 메트릭 갭 발생하나 기존 데이터 보존 |
| **Zone 장애** | Azure Monitor Zone-redundant → 데이터 수집 지속 |

---

## 9. GitOps (Flux v2)

### 9.1 Flux v2 구성 (ADR-014)

| 항목 | 설정 |
|-----|------|
| 설치 | `az k8s-configuration flux create` (AKS 애드온, 무료) |
| **인증 방식** | SSH Deploy Key (read-only, K8s Secret — flux-system NS) |
| **키 설정** | `--ssh-private-key-file ~/.ssh/flux_deploy_key` |
| **키 갱신** | `az k8s-configuration flux update`로 교체 |
| UI | Azure Portal → AKS → GitOps에서 구성 상태 확인 |

```bash
az k8s-configuration flux create \
  --resource-group rg-k8s-demo-mgmt \
  --cluster-name aks-mgmt \
  --name gitops-config \
  --namespace flux-system \
  --scope cluster \
  --url ssh://git@github.com/org/k8s-manifests.git \
  --ssh-private-key-file ~/.ssh/flux_deploy_key \
  --branch main \
  --kustomization name=infra path=./clusters/mgmt prune=true
```

> Public 리포지토리 사용 시 SSH 키 불필요 (`--url https://...`).

> **[향후 개선]** SSH Deploy Key(K8s Secret) → **Workload Identity 기반 OIDC 인증** 전환 검토.
> Azure DevOps/GitHub 연동 시 Managed Identity로 SSH 키 관리를 완전히 제거할 수 있음.
> 현재(ADR-014): SSH Deploy Key 방식 유지 — AKS GitOps 애드온의 Workload Identity 지원 성숙도 확인 후 적용 판단.

---

## 10. 백업 및 DR

### 10.1 백업 전략

| 계층 | 대상 | 백업 방법 | RPO |
|-----|------|----------|-----|
| L1 | AKS etcd | AKS 관리형 (자동) | 실시간 |
| L2 | K8s 리소스 + PV | AKS Backup → Azure Backup Vault (ZRS) | 24h |
| L3 | 관찰성 데이터 | Azure Monitor / Log Analytics 자체 보존 | 실시간 |
| L4 | Git 매니페스트 | GitHub → Flux v2 동기화 | 커밋 시 |

### 10.2 AKS Backup 설정

| 설정 | 값 |
|-----|-----|
| **서비스** | Azure Backup for AKS (GA 2025.02) |
| **Backup Vault** | `bv-k8s-demo` (rg-k8s-demo-common, **ZoneRedundant**) |
| **Auth** | Trusted Access (AKS ↔ Backup Vault) |
| **Schedule** | daily 02:00 UTC |
| **Retention** | 7일 (시연 목적) |
| **지원 PV** | CSI 기반 Azure Disk |
| **Cross-Region Restore** | **[현재] 미적용** / **[향후/옵션]** GRS Vault 구성 시 리전 장애 복구 가능 |

```hcl
resource "azurerm_data_protection_backup_vault" "bv" {
  name                = "bv-k8s-demo"
  resource_group_name = azurerm_resource_group.common.name
  location            = local.location
  datastore_type      = "VaultStore"
  redundancy          = "ZoneRedundant"       # ZRS Backup
}
```

### 10.3 DR 시나리오

| 시나리오 | 복구 방법 | 예상 RTO | 복구 완료 확인 |
|---------|----------|---------|----------------|
| Spot Eviction | Karpenter 자동 노드 재생성 | ~5분 | `kubectl get nodes` — 새 노드 Ready / `kubectl get pods -A` — 전체 Pod Running |
| Zone 장애 | Karpenter가 다른 Zone에 노드 재생성, Ingress는 자동 failover | ~5분 | `kubectl get nodes -L topology.kubernetes.io/zone` — Zone 2/3 노드 Ready / Azure Portal LB Health Probe 정상 |
| AKS 클러스터 장애 | `tofu apply` + AKS Backup 복원 | ~30분 | `kubectl get all -A` — 전체 Pod Running / `flux get all` — Flux reconcile 완료 / Ingress LB Public IP 응답 확인 |
| 리전 장애 | Cross-Region Restore (GRS 설정 시) | ~1시간 | 대상 리전 AKS `kubectl cluster-info` 응답 / Backup 복원 Job Completed / `curl https://<endpoint>` 정상 응답 |

---

## 11. 리소스 계획 및 비용

### 11.1 VM 가격 (Korea Central 기준)

| VM Size | On-Demand/h | Spot/h (예상) | 절감율 |
|---------|------------|--------------|--------|
| Standard_D2s_v5 (2vCPU/8GB) | ~$0.096 | ~$0.019 | ~80% |

> 실제 가격은 Azure Pricing Calculator (Korea Central 선택)에서 확인 권장.

### 11.2 운영 패턴별 비용

**공통 전제 조건**:

- AKS Standard Tier: $0.10/cluster/h × 3 클러스터
- Regular D2s_v5: ~$0.096/h (Korea Central 기준)
- Spot D2s_v5: ~$0.019/h (~80% 절감, 시장 변동 가능)
- System + Ingress: Regular VM — system 9대(Zone×3) + ingress 6대(Zone×3, mgmt·app1)
- Worker: Spot — Karpenter 자동 확장, 기본 0대
- Defender for Containers: 36 vCore 기준 ($6.87/vCore/월 ≈ $0.0094/vCore/h)
- Korea Central AZ 간 트래픽: **무료** (2024.06~ Microsoft 정책)

#### 패턴 A — 체크/검증 (2시간 세션 × 4회)

> `tofu apply`(~25분) + 실제 테스트(~1h 15분) + `tofu destroy`(~10분) = 2시간 세션

| 리소스 | 수량 | 단가 | 2h 비용 |
|-------|------|------|--------|
| AKS Control Plane (Standard) | 3 | $0.10/h | $0.60 |
| System Node (Regular D2s_v5) | 9 | ~$0.096/h | $1.73 |
| Ingress Node (Regular D2s_v5) | 6 | ~$0.096/h | $1.15 |
| Worker Node (Spot D2s_v5) | 3 | ~$0.019/h | $0.11 |
| Azure Load Balancer | 3 | ~$0.025/h | $0.15 |
| Defender for Containers | 36 vCore | ~$0.0094/vCore/h | $0.68 |
| ACR, Key Vault, Monitor 등 | — | — | ~$0.02 |
| **2시간 세션 소계** | | | **≈ $4.44** |
| **4회 총합** | | | **≈ $18** |

#### 패턴 B — 1일 시연 (24시간 풀런)

| 리소스 | 수량 | 단가 | 24h 비용 |
|-------|------|------|---------|
| AKS Control Plane (Standard) | 3 | $0.10/h | $7.20 |
| System Node (Regular D2s_v5) | 9 | ~$0.096/h | $20.74 |
| Ingress Node (Regular D2s_v5) | 6 | ~$0.096/h | $13.82 |
| Worker Node (Spot D2s_v5) | 3 | ~$0.019/h | $1.37 |
| Azure Load Balancer | 3 | ~$0.025/h | $1.80 |
| Defender for Containers | 36 vCore | ~$0.0094/vCore/h | $8.10 |
| ACR (Basic) | 1 | $0.167/일 | $0.17 |
| Key Vault, Monitor, Log Analytics | — | — | ~$0.50 |
| **1일 합계** | | | **≈ $54** |

#### 패턴 C — 지속 학습 (월 20일 기준)

| 리소스 | 수량 | 월 예상 비용 |
|-------|------|------------|
| AKS Control Plane (Standard Tier) | 3 | ~$48 |
| System Node (Regular D2s_v5 × 9) | 9 | ~$138 |
| Ingress Node (Regular D2s_v5 × 6) | 6 | ~$92 |
| Worker Node (Spot D2s_v5 × 3) | 3 | ~$9 |
| Defender for Containers | 36 vCore | ~$40 |
| Azure Managed Prometheus | 3 클러스터 | ~$3 |
| Azure Load Balancer | 3 | ~$15 |
| ACR (Basic) | 1 | ~$5 |
| Azure Key Vault | 1 | ~$1 |
| AKS Backup | 3 클러스터 | ~$3 |
| Log Analytics, App Insights | — | ~$0 (무료 범위) |
| Azure Disk (앱 PV만) | ~20Gi | ~$2 |
| **합계 (24h 풀런, Stop/Start 미적용)** | | **~$356/월** |
| **합계 (8h/일 운영, AKS Stop/Start 적용)** | | **~$200-220/월** |

#### 요약

| 패턴 | 시나리오 | 예상 비용 |
|-----|---------|---------|
| **A** | 2시간 세션 × 4회 (체크/검증) | **≈ $18** |
| **B** | 24시간 풀런 × 1회 (시연 당일) | **≈ $54** |
| **C** | 8h/일 × 20일/월 (지속 학습) | **≈ $200~356/월** |

> **패턴 A**: `tofu apply` ~25분 소요. 세션당 실제 테스트 가용 시간 약 1시간 15분.

### 11.3 비용 가드레일 & AKS Stop/Start

| 가드레일 | 구현 |
|---------|------|
| **AKS Stop/Start** | `az aks stop` / `az aks start` (야간/주말 자동화) |
| **Budget Alert** | Azure Cost Management → 월 **$250** 초과 시 이메일 알림 |
| **Spot + Karpenter** | Spot 전용 입찰, Zone 3개 분산으로 Spot 용량 풀 확대 — On-Demand 미사용 (정책) |
| **AKS Cost Analysis** | Azure Portal 네임스페이스별 비용 확인 (Standard Tier 기본 포함) |
| **Cross-AZ 트래픽** | Korea Central AZ 간 트래픽 **무료** |

**Korea Central 서비스별 AZ 지원**:

| 서비스 | AZ 지원 | 설정 |
|-------|---------|-----|
| AKS Control Plane | ✅ 자동 | `sku_tier = "Standard"` 필수 |
| AKS Node Pool | ✅ | `zones = ["1","2","3"]` 수동 설정 |
| Azure LB Standard | ✅ 자동 Zone-redundant | 별도 설정 불필요 |
| Managed Disk Premium SSD | ✅ ZRS | `skuName: Premium_ZRS` |
| Managed Disk Ultra / P SSD v2 | ❌ | ZRS 미지원 |
| Azure Key Vault | ✅ 자동 | 별도 설정 불필요 |
| ACR (전 SKU) | ✅ 자동 | 2024년~ 기본값 |
| Azure Monitor Workspace | ✅ 자동 | 별도 설정 불필요 |
| Log Analytics Workspace | ✅ 자동 | 별도 설정 불필요 |
| Azure Backup Vault | ✅ ZRS 옵션 | `redundancy = "ZoneRedundant"` |

**AKS Stop/Start 자동화**:

```bash
# 야간 정지 (매일 22:00 KST)
az aks stop -g rg-k8s-demo-mgmt -n aks-mgmt --no-wait
az aks stop -g rg-k8s-demo-app1 -n aks-app1 --no-wait
az aks stop -g rg-k8s-demo-app2 -n aks-app2 --no-wait

# 아침 시작 (매일 09:00 KST)
az aks start -g rg-k8s-demo-mgmt -n aks-mgmt --no-wait
az aks start -g rg-k8s-demo-app1 -n aks-app1 --no-wait
az aks start -g rg-k8s-demo-app2 -n aks-app2 --no-wait
```

> Azure Automation Account 또는 Logic App으로 스케줄 자동화 가능.

**AKS Stop 상태에서도 과금되는 항목**:

| 항목 | 비고 |
|-----|------|
| Azure Disk (OS 디스크 + PV) | 용량 기반 과금 유지 |
| Public IP (Static) | 보유만으로 ~$0.005/h 과금 |
| Azure Monitor Workspace / Log Analytics | 기본 보존 비용 |
| Azure Key Vault / ACR | 운영 상태와 동일 과금 |
| Azure Backup Vault | 스냅샷 스토리지 보존 비용 |

---

## 12. 설치 워크플로우

### 12.1 사전 준비

**필수 도구**:

```bash
az login                          # Azure CLI 인증
tofu version                      # OpenTofu 1.11+
kubectl version --client          # kubectl
helm version                      # Helm 3
```

**Azure 구독 쿼터 확인 (Korea Central)**:

| 리소스 | 최소 필요 쿼터 | 확인 명령 |
|-------|-------------|----------|
| Standard Dv5 Regular vCPUs | **30** (system 9 + ingress 6 × 2vCPU) | `az vm list-usage -l koreacentral -o table` |
| Standard Dv5 Spot vCPUs | **6** (worker 3 × 2vCPU, 최소) | 동일 |
| Public IP Addresses | **4** (AKS LB ×3 + Bastion ×1) | 동일 |
| Load Balancers | 3 | 동일 |

> AKS Private Cluster이므로 API Server에 Public IP 없음. Bastion용 Public IP 1개 포함.
> Korea Central Regular/Spot vCPU 쿼터는 기본값이 낮을 수 있음.
> 부족 시: Azure Portal → Subscription → Usage + quotas → 증가 요청 (보통 1~2영업일).

**Azure 리소스 프로바이더 등록**:

```bash
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.Monitor
az provider register --namespace Microsoft.AlertsManagement
```

### 12.2 OpenTofu 코드 구조

```
azure-k8s-terraform/
├── main.tf                 # Root module, provider 설정
├── variables.tf            # 입력 변수 정의 (acr_name 등 전역 유니크 값 포함)
├── outputs.tf              # 출력 값 (kubeconfig 경로 등)
├── locals.tf               # 클러스터 스펙, CIDR, 이름 규칙, Zone 설정
├── terraform.tfvars        # 환경별 변수 값
├── modules/
│   ├── network/            # VNet(×3), NSG, VNet Peering
│   ├── aks/                # AKS 클러스터, Node Pool(system/ingress/worker), 애드온
│   ├── identity/           # Managed Identity, Workload Identity, RBAC
│   ├── keyvault/           # Key Vault (RBAC mode), Private Endpoint
│   ├── acr/                # Container Registry
│   ├── monitoring/         # Monitor Workspace, Log Analytics, App Insights
│   └── backup/             # Backup Vault (ZoneRedundant), Backup Policy
├── addons/
│   ├── install.sh          # Phase 2 진입점
│   └── scripts/            # 개별 Addon 설치 스크립트
├── generated/              # kubeconfig 등 생성 파일 (.gitignore)
└── document/
    └── azure/              # 아키텍처 문서
```

### 12.3 Phase 1: Infrastructure (`tofu apply`, 20~30분)

```
tofu apply
  ├─ Resource Groups (common, mgmt, app1, app2)
  ├─ VNet × 3 (10.1~10.3.0.0/16) + NSG
  ├─ VNet Peering (mgmt↔app1, mgmt↔app2, app1↔app2)
  ├─ Azure Key Vault + RBAC
  ├─ Azure Monitor Workspace
  ├─ Log Analytics Workspace
  ├─ Azure Backup Vault (ZoneRedundant)
  ├─ ACR (Basic)
  ├─ AKS Clusters × 3 (mgmt, app1, app2)
  │    ├─ sku_tier: Standard
  │    ├─ kubernetes_version: "1.34"
  │    ├─ networkDataplane: cilium
  │    ├─ monitor_metrics {}
  │    ├─ oms_agent {}
  │    ├─ key_vault_secrets_provider {}
  │    ├─ System Node Pool (Regular, zones=[1,2,3], node_count=3)
  │    ├─ Ingress Node Pool (Regular, zones=[1,2,3], node_count=3, Taint)
  │    ├─ Worker Node Pool (Spot, zones=[1,2,3], node_count=0 — Karpenter)
  │    └─ Node Auto-Provisioning (Karpenter v1.6.5-aks)
  └─ Managed Identity + Workload Identity Federation
                    ↓
          az aks get-credentials (kubeconfig 생성)
```

> Phase 1에서 Managed Cilium, Prometheus, Container Insights, Key Vault CSI, Karpenter 자동 활성화.

**`locals.tf` 핵심 설정**:

```hcl
locals {
  location = "koreacentral"
  zones    = ["1", "2", "3"]

  clusters = {
    mgmt = { has_ingress_pool = true,  vnet_key = "mgmt" }
    app1 = { has_ingress_pool = true,  vnet_key = "app1" }
    app2 = { has_ingress_pool = false, vnet_key = "app2" }  # Ingress 미배포
  }

  # Clusters that get an ingress node pool (mgmt + app1)
  clusters_with_ingress = {
    for k, v in local.clusters : k => v if v.has_ingress_pool
  }
}
```

**노드풀 Terraform 핵심 패턴**:

```hcl
# AKS 클러스터 (Standard Tier + AZ)
resource "azurerm_kubernetes_cluster" "aks" {
  sku_tier           = "Standard"
  kubernetes_version = "1.34"
  location           = local.location

  default_node_pool {           # System Pool
    node_count = 3
    zones      = local.zones
  }
}

# Ingress 전용 (Regular + AZ + Taint)
resource "azurerm_kubernetes_cluster_node_pool" "ingress" {
  node_count  = 3
  priority    = "Regular"
  zones       = local.zones
  node_taints = ["dedicated=ingress:NoSchedule"]
  node_labels = { "role" = "ingress" }
}

# Worker — NAP/Karpenter가 관리 (Terraform에서 별도 node pool 생성 안 함)
# node_provisioning_profile { mode = "Auto" } 로 활성화
# Worker 노드 설정은 addons/scripts/08-karpenter-nodepool.sh 참조

# Backup Vault (ZRS)
resource "azurerm_data_protection_backup_vault" "bv" {
  redundancy = "ZoneRedundant"
}
```

### 12.4 Phase 2: Addon Installation (`./addons/install.sh --cluster all`, 10~15분)

| # | 스크립트 | 대상 | 버전 | 의존성 |
|---|---------|------|------|--------|
| 00 | `00-priority-classes.sh` | 전 클러스터 | — | kubeconfig |
| 00b | `00b-gateway-api.sh` | 전 클러스터 | **v1.3.0** | priority-classes |
| 01 | `01-cert-manager.sh` | mgmt only | **v1.19.x** | AKS 생성 (Workload Identity) |
| 02 | `02-external-secrets.sh` | 전 클러스터 | **Helm 0.10.x** | Workload Identity |
| 03 | `03-reloader.sh` | 전 클러스터 | **Helm 1.x** | 없음 (독립 설치) |
| 04 | `04-istio.sh` | mgmt + app1 | **asm-1-28** | cert-manager |
| 05 | `05-kyverno.sh` | app1/app2 | **Helm chart v3.7.1 / App v1.16.x** | 없음 (독립 설치) |
| 06 | `06-flux.sh` | 전 클러스터 | AKS 자동 관리 | AKS 생성 |
| 07 | `07-kiali.sh` | mgmt only | **v2.21 (Helm 1.28.0)** | Istio |
| 08 | `08-karpenter-nodepool.sh` | 전 클러스터 | Karpenter v1.6.5-aks | NAP 활성화 |
| 09 | `09-backup-extension.sh` | 전 클러스터 | AKS 자동 관리 | Backup Vault |
| 10 | `10-defender.sh` | 전 클러스터 | AKS 자동 관리 | AKS 생성 |
| 11 | `11-budget-alert.sh` | 구독 레벨 | — | 없음 |
| 12 | `12-aks-automation.sh` | 구독 레벨 | — | 없음 |
| 13 | `13-hubble.sh` | 전 클러스터 | Cilium 1.14.10 (AKS 관리) | AKS 생성 |
| 15 | `15-tetragon.sh` | 전 클러스터 | **Tetragon v1.4.0** | Managed Cilium |
| 16 | `16-otel-collector.sh` | 전 클러스터 | **OTel Collector v0.116.0** | App Insights |
| 19 | `19-vpa.sh` | 전 클러스터 | **VPA v4.7.1 (Fairwinds)** | 없음 (독립 설치) |
| 14 | `14-verify-clusters.sh` | 검증 | — | 전체 완료 (항상 마지막) |

> **verify-clusters.sh 체크 항목**: 전 클러스터 노드 Ready / 전 Pod Running(또는 Completed) / Managed Cilium HubbleRelay Ready / Flux GitRepository/Kustomization Reconciled / Istio istiod Ready (mgmt·app1) / Kyverno admission webhook Ready (app1·app2) / ESO ClusterSecretStore Ready / Reloader Deployment Ready / Key Vault에 TLS 인증서 동기화 확인

**AKS v1.34 Addon 버전 호환성**:

| Addon | 버전 | 관리 방식 | K8s 1.34 호환 |
|-------|------|---------|-------------|
| Managed Cilium | 1.14.10 | AKS 자동 관리 | ✅ |
| Istio Add-on | **asm-1-28** | AKS 자동 관리 | ✅ (asm-1-25 이하 EOL) |
| Flux v2 GitOps | N-2 최신 자동 적용 | AKS 자동 관리 | ✅ |
| NAP/Karpenter | 1.6.5-aks (`karpenter.sh/v1`) | AKS 자동 관리 | ✅ |
| Gateway API CRD | **v1.3.0** | 수동 설치 | ✅ |
| cert-manager | **v1.19.x** | Helm 수동 설치 | ✅ |
| Kyverno | **Helm chart v3.7.1 / App v1.16.x** | Helm 수동 설치 | ✅ |
| Kiali | **v2.21 (Helm 1.28.0)** | Helm 수동 설치 | ✅ |
| External Secrets Operator | **Helm 0.10.x** | Helm 수동 설치 | ✅ |
| Stakater Reloader | **Helm 1.x** | Helm 수동 설치 | ✅ |
| Key Vault CSI | AKS 자동 관리 | AKS 자동 관리 | ✅ |
| Defender for Containers | AKS 자동 관리 | AKS 자동 관리 | ✅ |
| AKS Backup Extension | AKS 자동 관리 | AKS 자동 관리 | ✅ |
| Container Insights | AKS 자동 관리 | AKS 자동 관리 | ✅ |
| Cilium Tetragon | **v1.4.0** | Helm 수동 설치 | ✅ |
| OpenTelemetry Collector | **v0.116.0** | Helm 수동 설치 | ✅ |
| VPA (Fairwinds) | **v4.7.1** | Helm 수동 설치 | ✅ |

**Addon HA 설정 (Helm 설치 대상)**:

| Addon | replicas | PDB | HPA | TopologySpread | PriorityClass |
|-------|----------|-----|-----|---------------|--------------|
| cert-manager | 2 | minAvailable: 1 | min 2 / max 4 / CPU 80% | zone | platform-critical |
| ESO | 2 | chart 내장 | min 2 / max 4 / CPU 80% | zone | platform-critical |
| Reloader | 2 | minAvailable: 1 | min 2 / max 3 / CPU 80% | — | platform-critical |
| Kyverno (admission) | 3 | minAvailable: 2 | min 3 / max 5 / CPU 70% | zone | platform-critical |
| Kiali | 1 | — | — | — | workload-high |
| Tetragon | DaemonSet | — | — | — | system-node-critical |
| OTel Collector | 2 | minAvailable: 1 | min 2 / max 5 / CPU 70% | zone | platform-critical |
| VPA | 1 | — | — | — | platform-critical |

> Kyverno ClusterPolicy `generate-pdb`가 replicas > 1인 사용자 Deployment에 PDB를 자동 생성한다.
> `require-topology-spread` (Audit 모드)가 TopologySpreadConstraints 미설정 감지 시 리포트한다.

**`install.sh` CLI 사용법**:

```bash
# 전체 클러스터 설치
./addons/install.sh --cluster all

# 특정 클러스터만
./addons/install.sh --cluster mgmt
./addons/install.sh --cluster app1

# Dry-run (실제 실행 없이 순서 확인)
./addons/install.sh --cluster all --dry-run
```

> **향후 개선 방향 (ADR-009)**: Addon 수 증가 시 Flux `HelmRelease` 또는 OpenTofu `helm_release`로
> 전환하여 IaC/GitOps 방식의 선언적 관리 가능 (드리프트 감지 + 버전 관리 포함).

---

## 13. 서비스 접근 레퍼런스

### 13.1 관리자 kubectl 접근 (Bastion 경유)

> 상세 아키텍처 설명은 [5.7 관리자 접근 아키텍처](#57-관리자-접근-아키텍처-adr-021) 참조.
> AKS Private Cluster — API Server 공개 엔드포인트 없음, 모든 kubectl 작업은 Bastion → Jump VM 경유 필수.

```bash
# Step 1: Azure Portal → rg-k8s-demo-mgmt → bastion-k8s-demo → Connect
#         브라우저에서 Jump VM (vm-jumpbox) SSH 세션 열기

# Step 2: Jump VM에서 AKS kubeconfig 취득
az login                          # Entra ID 인증
az aks get-credentials -g rg-k8s-demo-mgmt -n aks-mgmt
az aks get-credentials -g rg-k8s-demo-app1 -n aks-app1
az aks get-credentials -g rg-k8s-demo-app2 -n aks-app2

# Step 3: kubectl 사용 (Jump VM → AKS API Server, VNet 내부 통신)
kubectl get nodes -A
kubectl get pods -A
```

### 13.2 Azure Portal

| 서비스 | 접근 경로 | 인증 |
|--------|----------|------|
| 메트릭 (Prometheus) | AKS → Insights | Entra ID |
| Grafana 대시보드 | AKS → Insights → Grafana 탭 | Entra ID |
| 로그 (KQL) | Log Analytics → Logs | Entra ID |
| 트레이스 / Application Map | Application Insights | Entra ID |
| GitOps 상태 | AKS → GitOps | Entra ID |
| 비용 분석 | Cost Management | Entra ID |
| 보안 알림 | Defender for Cloud | Entra ID |
| 백업 상태 | Backup Center | Entra ID |

### 13.3 Port-Forward (클러스터 내 컴포넌트)

| 서비스 | Namespace | Port | URL |
|--------|-----------|------|-----|
| Kiali | istio-system | 20001 | http://localhost:20001/kiali |
| Hubble UI | kube-system | 12000 | http://localhost:12000 |

### 13.4 LoadBalancer (Azure LB Public IP, Zone-redundant)

| 클러스터 | 서비스 | Namespace | Port |
|---------|--------|-----------|------|
| mgmt | Istio Ingress Gateway | istio-system | 80/443 |
| app1 | Istio Ingress Gateway | istio-system | 80/443 |
| app2 | (Ingress 미배포) | — | — |

### 13.5 자격증명

```bash
# AKS kubeconfig
az aks get-credentials -g rg-k8s-demo-mgmt -n aks-mgmt
az aks get-credentials -g rg-k8s-demo-app1 -n aks-app1
az aks get-credentials -g rg-k8s-demo-app2 -n aks-app2

# Key Vault 시크릿
az keyvault secret list --vault-name <kv-name> -o table
az keyvault secret show --vault-name <kv-name> --name <secret-name> --query value -o tsv
```

> 모든 Azure 관리형 서비스는 Entra ID 인증. 별도 패스워드 관리 불필요.
