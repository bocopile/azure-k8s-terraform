# Azure Kubernetes 멀티클러스터 아키텍처

> **버전**: 3.0.0
> **Kubernetes**: AKS v1.31
> **최종 수정일**: 2026-02-26
> **환경**: Azure Spot VM + Azure 관리형 서비스 (시연/학습용)

---

## 목차

1. [개요](#1-개요)
2. [아키텍처 결정 기록 (ADR)](#2-아키텍처-결정-기록-adr)
3. [아키텍처 불변 조건](#3-아키텍처-불변-조건-architecture-contract)
4. [클러스터 토폴로지](#4-클러스터-토폴로지)
5. [네트워크 아키텍처](#5-네트워크-아키텍처)
6. [스토리지 아키텍처](#6-스토리지-아키텍처)
7. [보안 아키텍처](#7-보안-아키텍처)
8. [관찰성 아키텍처](#8-관찰성-아키텍처)
9. [백업 및 DR](#9-백업-및-dr)
10. [리소스 계획 및 비용](#10-리소스-계획-및-비용)
11. [설치 워크플로우](#11-설치-워크플로우)
12. [서비스 접근 레퍼런스](#12-서비스-접근-레퍼런스)

---

## 1. 개요

### 1.1 프로젝트 목적

Azure 관리형 서비스를 최대한 활용하여 **Kubernetes 멀티클러스터** 환경을 구축합니다.
**Spot VM**과 **AKS Stop/Start**로 시연/학습 비용을 최소화합니다.

### 1.2 대상 환경 및 SLO

| 항목 | 값 |
|-----|-----|
| **환경 유형** | 시연 / 학습 / PoC |
| **가용성 목표** | 95% (Spot Eviction 허용) |
| **RTO** | 30분 (AKS 재생성 기준) |
| **RPO** | 24시간 (일일 백업 기준) |

> Spot VM 특성상 Eviction 발생 가능. 시연 목적이므로 허용.

### 1.3 기술 스택

| 영역 | 기술 |
|-----|------|
| **IaC** | OpenTofu 1.11 + Shell Script |
| **컴퓨팅** | AKS Managed (v1.31), Spot VM, Node Auto-Provisioning (Karpenter) |
| **네트워크** | Azure CNI Overlay + Managed Cilium + Azure Load Balancer |
| **Service Mesh** | AKS Istio Add-on (관리형) |
| **GitOps** | AKS GitOps (Flux v2) |
| **시크릿/PKI** | Azure Key Vault + Key Vault CSI Driver + cert-manager |
| **메트릭** | Azure Managed Prometheus + Azure Portal Grafana |
| **로그** | Container Insights + Log Analytics |
| **트레이싱** | Application Insights (OpenTelemetry) |
| **네트워크 관찰성** | Cilium Hubble + Kiali |
| **보안** | PSA + Kyverno + Microsoft Defender for Containers + Cilium NetworkPolicy |
| **백업** | AKS Backup (Azure Backup Vault) |
| **비용 최적화** | Spot VM, AKS Stop/Start, AKS Cost Analysis, Budget Alert |

### 1.4 제약 조건

- Ansible 미사용 (Shell Script로 대체)
- Helmfile 미사용 (Helm CLI 직접 사용)
- AKS Free Tier 사용 (SLA 미보장, 노드 10개 이하 권장)
- Azure Key Vault Standard SKU (Premium/HSM 미사용)
- AKS Istio Add-on Gateway API 지원은 Preview (GA 예정 2026.05)
- Spot VM: Eviction 시 Karpenter가 자동 노드 재생성

---

## 2. 아키텍처 결정 기록 (ADR)

| ADR | 상태 | 결정 요약 |
|-----|------|----------|
| **ADR-001** | Accepted | mgmt 클러스터에 플랫폼 서비스 집중, Azure 관리형 서비스로 클러스터 부하 최소화 |
| **ADR-002** | Accepted | AKS Managed Control Plane (Free Tier) 사용 |
| **ADR-003** | Accepted | PSA(baseline) + Kyverno 2-Layer 보안. Kyverno는 app 클러스터에만 배치 |
| **ADR-004** | Accepted | Azure Key Vault + CSI Driver로 시크릿 관리 (Volume Mount 방식, etcd 미저장) |
| **ADR-005** | Accepted | Azure CNI Overlay + Managed Cilium (eBPF 데이터플레인, AKS 자동 관리) |
| **ADR-006** | Accepted | Azure Managed Prometheus + Container Insights 기반 관찰성 |
| **ADR-007** | Accepted | Spot VM + Karpenter(NAP) + Priority Expander로 비용 60~90% 절감 |
| **ADR-008** | Accepted | OpenTofu 1.11 사용 (MPL 2.0 라이선스) |
| **ADR-009** | Accepted | 2단계 워크플로우: Phase 1(tofu apply) → Phase 2(addons/install.sh) |
| **ADR-010** | Accepted | Log Analytics로 로그 수집 (5GB/월 무료 Tier) |
| **ADR-011** | Accepted | AKS Istio Add-on + Ingress Gateway로 서비스 노출 (독립 메쉬 방식) |
| **ADR-012** | Accepted | 비용 가드레일: AKS Stop/Start + Budget Alert + Spot + Free Tier |
| **ADR-013** | Accepted | AKS Backup (Azure Backup Vault) 기반 클러스터 백업 |
| **ADR-014** | Accepted | AKS GitOps Flux v2 (무료 애드온) 기반 배포 |
| **ADR-015** | Accepted | Defender for Containers 기반 런타임 보안 + 이미지 스캔 |
| **ADR-016** | Accepted | Egress: Azure LB SNAT 사용 (NAT Gateway 미도입, 시연 환경 비용 우선) |
| **ADR-017** | Accepted | cert-manager: Let's Encrypt + DNS-01 챌린지 (Azure DNS 연동) |
| **ADR-018** | Accepted | ACR Basic SKU, Kubelet Identity로 AcrPull 연동 |

### ADR-005 상세: Managed Cilium

| 항목 | 설정 |
|-----|------|
| 데이터플레인 | Cilium eBPF (kube-proxy 대비 30% 지연 감소) |
| 업그레이드 | AKS 버전과 동기화, 자동 업그레이드 |
| Network Policy | Cilium 네이티브 |
| Hubble | 수동 활성화 (무료) |
| 비용 | **무료** (ACNS 고급 기능은 유료) |

### ADR-006 상세: Azure Managed Prometheus

| 항목 | 설정 |
|-----|------|
| 활성화 | AKS 클러스터 생성 시 `monitor_metrics {}` 원클릭 |
| 데이터 보존 | **18개월** (추가 비용 없이 포함) |
| HA | Azure에서 자동 보장 |
| PromQL | 완전 지원 |
| 비용 (시연 규모) | **~$1-5/월** (ingestion 기준) |

### ADR-014 상세: AKS GitOps Flux v2

| 항목 | 설정 |
|-----|------|
| 설치 | `az k8s-configuration flux create` (AKS 애드온) |
| UI | Azure Portal에서 구성 상태 확인 (CLI/YAML 기반 운영) |
| 리소스 | ~100MB RAM (경량) |
| 비용 | **무료** |

### ADR-014 상세: Flux v2 시크릿 관리

Private Git 리포지토리 접근 시 인증 처리:

| 항목 | 설정 |
|-----|------|
| **인증 방식** | SSH Deploy Key (read-only) |
| **키 생성** | `az k8s-configuration flux create` 시 `--ssh-private-key-file` 옵션 |
| **키 저장** | AKS 클러스터 내 `flux-system` namespace의 K8s Secret |
| **키 갱신** | `az k8s-configuration flux update`로 새 키 교체 |

```bash
# Flux GitOps 구성 (SSH 인증)
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

> Public 리포지토리 사용 시 SSH 키 불필요 (`--url https://...` 사용).
> PAT(Personal Access Token) 방식도 가능하나, Deploy Key가 scope가 좁아 보안상 권장.

### ADR-017 상세: cert-manager 인증서 관리

| 항목 | 설정 |
|-----|------|
| **CA** | Let's Encrypt (Production) |
| **챌린지 방식** | **DNS-01** (Azure DNS Zone 연동) |
| **인증** | Workload Identity → Managed Identity → Azure DNS Zone Contributor |
| **발급 대상** | Istio Ingress Gateway TLS 인증서 (`*.example.com`) |
| **갱신** | cert-manager 자동 갱신 (만료 30일 전) |

```yaml
# ClusterIssuer 예시
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
> Key Vault에 인증서를 저장하지 않고 K8s Secret으로 직접 관리 (cert-manager 기본 동작).

### ADR-003 상세: Kyverno 배치 범위

| 클러스터 | Kyverno | 이유 |
|---------|---------|------|
| **mgmt** | 미설치 | 플랫폼/운영자 영역, PSA baseline만 적용 |
| **app1/app2** | Enforce 모드 | 개발팀 워크로드 정책 강제 |

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
| **C6** | System Node Pool은 Regular VM 유지 (Spot 미적용) | ADR-007 |
| **C7** | IaC는 OpenTofu 사용, Terraform 문법 호환성 유지 | ADR-008 |
| **C8** | 인프라(tofu apply)와 Addon 설치(addons/install.sh)는 2단계 분리 | ADR-009 |
| **C9** | 백업은 Azure Backup Vault에 저장 (클러스터 독립적) | ADR-013 |
| **C10** | 월 비용 Budget Alert + AKS Stop/Start 자동화 설정 | ADR-012 |

---

## 4. 클러스터 토폴로지

### 4.1 클러스터 역할

| 클러스터 | 역할 | 클러스터 내 컴포넌트 |
|---------|------|-------------------|
| **mgmt** | 플랫폼 서비스 | Istio (AKS Add-on), Kiali, cert-manager, Flux v2 |
| **app1** | 워크로드 A | 애플리케이션, Kyverno, Istio Sidecar, Flux v2 |
| **app2** | 워크로드 B | 애플리케이션, Kyverno, Flux v2 |

**Azure 관리형 (클러스터 외부 또는 AKS 애드온)**:

| 서비스 | 유형 | 적용 범위 |
|-------|------|----------|
| Managed Cilium | AKS 네트워크 데이터플레인 | 전 클러스터 |
| Managed Prometheus | Azure Monitor Workspace | 전 클러스터 |
| Container Insights | AKS 애드온 (DaemonSet) | 전 클러스터 |
| Key Vault CSI Driver | AKS 애드온 | 전 클러스터 |
| Defender for Containers | Azure Defender 플랜 | 전 클러스터 |
| AKS Backup | Azure Backup Extension | 전 클러스터 |
| Karpenter (NAP) | AKS Node Auto-Provisioning | 전 클러스터 |
| Flux v2 | AKS GitOps 애드온 | 전 클러스터 |

### 4.2 AKS 클러스터 스펙

| 클러스터 | Node Pool | VM Size | 노드 수 | Priority | 비고 |
|---------|-----------|---------|--------|----------|------|
| mgmt | system | Standard_D2s_v5 | 1 | Regular | 안정성 보장 |
| mgmt | worker | Standard_D2s_v5 | 1 | **Spot** | Istio, Kiali, cert-manager |
| app1 | system | Standard_D2s_v5 | 1 | Regular | 안정성 보장 |
| app1 | worker | Standard_D2s_v5 | 1~2 | **Spot** | 앱 워크로드 |
| app2 | system | Standard_D2s_v5 | 1 | Regular | 안정성 보장 |
| app2 | worker | Standard_D2s_v5 | 1~2 | **Spot** | 앱 워크로드 |

> Standard_D2s_v5 = 2 vCPU / 8GB RAM. Azure 관리형 서비스 활용으로 모든 노드 동일 스펙 가능.

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
          values: ["spot", "on-demand"]    # Spot 우선, 불가 시 On-Demand
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
  limits:
    cpu: "20"
    memory: "40Gi"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

### 4.4 네트워크 구성

| 리소스 | CIDR / 설정 |
|-------|------------|
| **VNet** | 10.0.0.0/8 |
| **mgmt Subnet** | 10.1.0.0/16 |
| **app1 Subnet** | 10.2.0.0/16 |
| **app2 Subnet** | 10.3.0.0/16 |
| **Pod CIDR (Overlay)** | 클러스터별 자동 할당 |
| **Service CIDR** | 클러스터별 자동 할당 |

### 4.5 Resource Group 구성

| Resource Group | 포함 리소스 |
|---------------|-----------|
| **rg-k8s-demo-common** | VNet, NSG, Key Vault, ACR, DNS Zone, Azure Monitor Workspace, Log Analytics Workspace, Backup Vault |
| **rg-k8s-demo-mgmt** | AKS mgmt, Managed Identity |
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
    network_dataplane   = "cilium"
  }
}
```

### 5.2 Azure Load Balancer

| 항목 | 설정 |
|-----|------|
| SKU | Standard |
| Type | Public (시연용) |
| Outbound Type | `loadBalancer` |
| 역할 | `Service type=LoadBalancer` 자동 프로비저닝 |

### 5.3 Gateway API

- CRD 설치 후 Istio Gateway 연동
- AKS Istio Add-on의 Gateway API 지원: **Preview** (GA 예정 2026.05)
- GA 전까지는 Istio `Gateway` + `VirtualService` (classic API) 사용

### 5.4 AKS Istio Add-on

| 클러스터 | 배포 범위 |
|---------|----------|
| **mgmt** | Istiod (관리형) + Ingress Gateway |
| **app1** | Istiod (관리형) + Ingress Gateway + Sidecar Injection (mTLS STRICT) |
| **app2** | 미배포 (선택적) |

| 항목 | 설정 |
|-----|------|
| 설치 | `az aks mesh enable` |
| 업그레이드 | Canary 방식 (두 리비전 병행 가능) |
| 지원 리비전 | asm-1-24, asm-1-25 |
| 비용 | **무료** (사이드카 컴퓨팅 리소스만 과금) |

**메쉬 토폴로지 — 독립 메쉬 (Independent Mesh)**:

mgmt와 app1은 **각각 독립된 Istio 메쉬**로 운영한다.

| 항목 | 설정 |
|-----|------|
| 토폴로지 | **독립 메쉬** (클러스터당 1 메쉬) |
| 클러스터 간 서비스 디스커버리 | 없음 (VNet Peering으로 L3 통신만 가능) |
| mTLS 범위 | 각 클러스터 내부만 (cross-cluster mTLS 불필요) |

> Multi-primary / Primary-Remote는 미적용. 시연 환경에서 클러스터 간 Istio 서비스 디스커버리가 불필요하며,
> AKS Istio Add-on이 멀티클러스터 메쉬를 공식 지원하지 않음.
> 클러스터 간 통신이 필요한 경우 VNet Peering + Kubernetes Service(ClusterIP) 직접 호출로 해결.

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
| **Istio Egress Gateway** | 미사용 (시연 환경에서 외부 API 제어 불필요) |
| **NAT Gateway** | **미도입** |

> NAT Gateway 미도입 근거: 시연 환경에서 안정적인 Outbound IP 유지 필요성이 낮고,
> NAT Gateway 비용(~$32/월 + 데이터 처리 비용)이 시연 예산 대비 과도.
> Spot VM 교체 시 SNAT IP가 변경될 수 있으나 시연에 영향 없음.
> 프로덕션 전환 시 NAT Gateway 도입 권장.

### 5.6 Cross-Cluster 통신

| 방식 | 구현 |
|-----|------|
| **VNet Peering** | mgmt ↔ app1, mgmt ↔ app2, app1 ↔ app2 |
| **Private Endpoint** | Key Vault, Azure Monitor Workspace |
| **AKS API Server** | Public + Authorized IP Ranges (시연용) |

### 5.7 DNS 자동화

| 항목 | 설정 |
|-----|------|
| **Azure DNS Zone** | rg-k8s-demo-common에 생성 |
| **external-dns** | **미사용** (시연 환경에서 서비스 수가 적어 수동 관리) |
| **레코드 등록** | Istio Ingress Gateway의 Public IP를 수동으로 Azure DNS에 등록 |

> 프로덕션 전환 시 external-dns Helm 설치 후 Istio Gateway 어노테이션으로 자동 등록 권장.

---

## 6. 스토리지 아키텍처

### 6.1 Kubernetes StorageClass

| StorageClass | Provisioner | ReclaimPolicy | 용도 |
|-------------|-------------|---------------|------|
| **managed-csi** (기본) | disk.csi.azure.com | Delete | 일반 워크로드 |
| **managed-csi-retain** | disk.csi.azure.com | Retain | 상태 유지 필요 시 |
| **azurefile-csi** | file.csi.azure.com | Delete | ReadWriteMany 필요 시 |

> Azure 관리형 서비스 활용으로 **플랫폼 컴포넌트의 클러스터 내 PV 사용이 없음**.
> PV는 앱 워크로드 요구사항에 따라서만 사용.

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
| **L4 시크릿** | Azure Key Vault + CSI Driver (Volume Mount, etcd 미저장) | 전 클러스터 |
| **L5 런타임 보안** | Microsoft Defender for Containers (위협 탐지 + 악성코드) | 전 클러스터 |
| **L6 취약점 관리** | Defender for Containers (이미지 CVE 스캔 + 배포 차단) | 전 클러스터 |

### 7.2 Microsoft Defender for Containers

| 기능 | 설명 |
|-----|------|
| 런타임 위협 탐지 | 컨테이너 행동 분석 기반 실시간 탐지 |
| 이미지 취약점 스캔 | 레지스트리 + 실행 중 컨테이너 대상 |
| 노드 취약점 평가 | 노드 OS 레벨 스캔 |
| 악성코드 탐지 | 컨테이너 내 악성코드 감지 |
| 배포 차단 (게이팅) | 취약한 이미지 배포 자동 차단 |
| 비용 | ~$6.87/vCore/월 (20회 무료 스캔/vCore 포함) |

### 7.3 Key Vault CSI Driver

```
AKS Cluster
 └─ Key Vault CSI Driver (AKS 애드온)
      ├─ SecretProviderClass → Volume Mount로 시크릿 주입
      ├─ Auto-rotation (2분 간격 폴링)
      └─ Workload Identity Federation
           ├─ cert-manager → Key Vault (인증서)
           └─ 앱 워크로드 → Key Vault (시크릿)
```

- 시크릿이 etcd에 저장되지 않음 (Volume Mount 방식)
- AKS 공식 애드온, 무료
- Auto-rotation으로 시크릿 갱신 자동 반영

### 7.4 Kyverno 정책 (app 클러스터만)

| 정책 | 모드 | 내용 |
|-----|------|------|
| `restrict-image-registries` | Enforce | `acrkdemo.azurecr.io/*`, `docker.io/library/*`, `quay.io/*`, `registry.k8s.io/*` 허용 |
| `require-resource-limits` | Enforce | requests/limits 필수 |
| `disallow-privileged-containers` | Enforce | `privileged: false` 강제 |
| `require-labels` | Audit | app, version 라벨 필수 |

### 7.5 Azure Container Registry (ADR-018)

| 항목 | 설정 |
|-----|------|
| **이름** | `acrkdemo` |
| **SKU** | Basic (시연 목적, 10GB 포함) |
| **Resource Group** | rg-k8s-demo-common |
| **AKS 연동** | Kubelet Identity에 `AcrPull` 역할 할당 |
| **Admin 계정** | 비활성화 (Managed Identity만 사용) |

```hcl
resource "azurerm_container_registry" "acr" {
  name                = "acrkdemo"
  resource_group_name = azurerm_resource_group.common.name
  location            = var.location
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
 └─ System-assigned Managed Identity (AKS 운영)
 └─ Kubelet Identity → ACR (AcrPull)
 └─ Workload Identity Federation
      ├─ cert-manager → Key Vault (인증서)
      ├─ cert-manager → Azure DNS Zone (DNS-01 챌린지)
      ├─ Key Vault CSI Driver → Key Vault (시크릿)
      ├─ AKS Backup Extension → Backup Vault
      ├─ Container Insights Agent → Azure Monitor Workspace
      └─ Flux v2 → Git Repository (선택적)
```

---

## 8. 관찰성 아키텍처

### 8.1 스택 구성

| 영역 | 서비스 | 비용 (시연 규모) |
|-----|-------|----------------|
| **메트릭** | Azure Managed Prometheus → Azure Monitor Workspace | ~$1-5/월 |
| **시각화** | Azure Portal 내장 Grafana 대시보드 | **무료** |
| **로그** | Container Insights → Log Analytics Workspace | **무료** (5GB/월) |
| **트레이싱** | Application Insights (OpenTelemetry) | **무료** (5GB/월 공유) |
| **네트워크 플로우** | Cilium Hubble (UI + Relay) | **무료** |
| **서비스 그래프** | Kiali (Helm 설치) | Helm 직접 설치 |

### 8.2 데이터 흐름

```
AKS Cluster (mgmt / app1 / app2)
 ├─ Container Insights Agent (관리형 DaemonSet)
 │    ├─ Prometheus 메트릭 스크래핑 → Azure Monitor Workspace
 │    └─ 컨테이너 로그 수집 → Log Analytics Workspace
 ├─ Application Insights SDK / OTel → Application Insights (트레이스)
 └─ Cilium Hubble → Hubble UI (네트워크 플로우)

Azure Portal
 ├─ AKS Insights → Managed Prometheus 시각화 (내장 Grafana)
 ├─ Log Analytics → KQL 쿼리
 ├─ Application Insights → 분산 트레이스 / Application Map
 └─ AKS GitOps → Flux 구성 상태
```

### 8.3 OpenTofu 관찰성 구성

```hcl
# Azure Monitor Workspace (Managed Prometheus)
resource "azurerm_monitor_workspace" "prometheus" {
  name                = "mon-k8s-demo"
  resource_group_name = azurerm_resource_group.common.name
  location            = var.location
}

# Log Analytics Workspace
resource "azurerm_log_analytics_workspace" "common" {
  name                = "law-k8s-demo"
  resource_group_name = azurerm_resource_group.common.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# AKS에서 활성화
resource "azurerm_kubernetes_cluster" "aks" {
  monitor_metrics {}                          # Managed Prometheus

  oms_agent {                                 # Container Insights
    log_analytics_workspace_id = azurerm_log_analytics_workspace.common.id
  }
}
```

### 8.4 장애 시 동작

| 시나리오 | 동작 |
|---------|------|
| **클러스터 장애** | 메트릭/로그가 Azure Monitor에 저장되어 있으므로 **기존 데이터 유실 없음** |
| **Spot Eviction** | 노드 재생성 후 Agent 자동 재배포, 메트릭 갭 발생하나 기존 데이터 보존 |

> 관찰성 데이터가 **클러스터 외부(Azure Monitor)에 저장**되므로 클러스터 상태와 무관하게 데이터 보존.

### 8.5 Kiali

- Istio 서비스 그래프 시각화를 위해 mgmt + app1에 Helm 설치
- Managed Prometheus를 데이터 소스로 연동
- Azure Portal에 동등 기능이 없으므로 직접 설치 유지

---

## 9. 백업 및 DR

### 9.1 백업 전략

| 계층 | 대상 | 백업 방법 | RPO |
|-----|------|----------|-----|
| L1 | AKS etcd | AKS 관리형 (자동) | 실시간 |
| L2 | K8s 리소스 + PV | AKS Backup → Azure Backup Vault | 24h |
| L3 | 관찰성 데이터 | Azure Monitor / Log Analytics 자체 보존 | 실시간 |
| L4 | Git 매니페스트 | GitHub → Flux v2 동기화 | 커밋 시 |

### 9.2 AKS Backup 설정

| 설정 | 값 |
|-----|-----|
| **서비스** | Azure Backup for AKS (GA 2025.02) |
| **Backup Vault** | `bv-k8s-demo` (rg-k8s-demo-common) |
| **Auth** | Trusted Access (AKS ↔ Backup Vault) |
| **Schedule** | daily 02:00 UTC |
| **Retention** | 7일 (시연 목적) |
| **지원 PV** | CSI 기반 Azure Disk |
| **Cross-Region Restore** | 선택적 (GRS Vault 필요) |

### 9.3 DR 시나리오

| 시나리오 | 복구 방법 | 예상 RTO |
|---------|----------|---------|
| Spot Eviction | Karpenter 자동 노드 재생성 | ~5분 |
| AKS 클러스터 장애 | `tofu apply` + AKS Backup 복원 | ~30분 |
| 리전 장애 | Cross-Region Restore (GRS 설정 시) | ~1시간 |

---

## 10. 리소스 계획 및 비용

### 10.1 Spot VM 가격 (Korea Central)

| VM Size | On-Demand/h | Spot/h (예상) | 절감율 |
|---------|------------|--------------|--------|
| Standard_D2s_v5 (2vCPU/8GB) | ~$0.096 | ~$0.019 | ~80% |

### 10.2 월 예상 비용 (일 8시간, 월 20일)

| 리소스 | 수량 | 월 예상 비용 |
|-------|------|------------|
| AKS Control Plane (Free Tier) | 3 | $0 |
| System Node Pool (Regular D2s_v5) | 3 | ~$46 |
| Worker Node Pool (Spot D2s_v5) | 3 | ~$9 |
| Azure Managed Prometheus | 3 클러스터 | ~$3 |
| Log Analytics (5GB 무료) | 1 | ~$0 |
| Application Insights (5GB 공유) | 1 | ~$0 |
| Azure Key Vault | 1 | ~$1 |
| ACR (Basic) | 1 | ~$5 |
| Azure Load Balancer | 3 | ~$15 |
| Defender for Containers | ~12 vCore | ~$10 |
| AKS Backup | 3 클러스터 | ~$3 |
| Azure Disk (앱 PV만) | ~20Gi | ~$2 |
| VNet / Bandwidth | - | ~$3 |
| **합계 (8h/일)** | | **~$97/월** |
| **합계 (AKS Stop/Start 자동화 적용)** | | **~$55-65/월** |

### 10.3 비용 가드레일

| 가드레일 | 구현 |
|---------|------|
| **AKS Stop/Start** | `az aks stop` / `az aks start` (야간/주말 자동화) |
| **Budget Alert** | Azure Cost Management → 월 $100 초과 시 이메일 알림 |
| **Spot + Karpenter** | Spot 우선 입찰, 불가 시 On-Demand 폴백 |
| **Free Tier** | AKS Free, Key Vault 10K ops/월, Log Analytics 5GB/월 |
| **AKS Cost Analysis** | Azure Portal 네임스페이스별 비용 확인 (Standard tier 필요) |

### 10.4 AKS Stop/Start 자동화

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
> 정지 상태에서는 컴퓨팅 비용 $0, 스토리지/Static IP만 과금.

---

## 11. 설치 워크플로우

### 11.1 사전 준비

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
| Standard Dv5 Family vCPUs (Regular) | 6 vCPU (System Pool 3개 x 2) | `az vm list-usage -l koreacentral -o table` |
| Standard Dv5 Family vCPUs (Spot) | 10 vCPU (Worker Pool 5개 x 2) | 동일 |
| Public IP Addresses | 6 (AKS LB x3 + API Server x3) | 동일 |
| Load Balancers | 3 | 동일 |

> Korea Central Spot vCPU 쿼터는 기본값이 낮을 수 있음.
> 부족 시: Azure Portal → Subscription → Usage + quotas → 증가 요청 (보통 1~2영업일).

**Azure 리소스 프로바이더 등록**:

```bash
az provider register --namespace Microsoft.ContainerService    # AKS
az provider register --namespace Microsoft.KubernetesConfiguration  # Flux GitOps
az provider register --namespace Microsoft.Monitor             # Managed Prometheus
az provider register --namespace Microsoft.AlertsManagement    # Alerts
```

### 11.2 OpenTofu 코드 구조

```
azure-k8s-terraform/
├── main.tf                 # Root module, provider 설정
├── variables.tf            # 입력 변수 정의
├── outputs.tf              # 출력 값 (kubeconfig 경로 등)
├── locals.tf               # 클러스터 스펙, CIDR, 이름 규칙
├── terraform.tfvars        # 환경별 변수 값
├── modules/
│   ├── network/            # VNet, Subnet, NSG, Peering
│   ├── aks/                # AKS 클러스터, Node Pool, 애드온
│   ├── identity/           # Managed Identity, Workload Identity, RBAC
│   ├── keyvault/           # Key Vault, Access Policy
│   ├── acr/                # Container Registry
│   ├── monitoring/         # Monitor Workspace, Log Analytics, App Insights
│   └── backup/             # Backup Vault, Backup Policy
├── addons/
│   ├── install.sh          # Phase 2 진입점
│   └── scripts/            # 개별 Addon 설치 스크립트
├── generated/              # kubeconfig 등 생성 파일 (.gitignore)
└── document/
    └── azure/              # 아키텍처 문서
```

### 11.3 Phase 1: Infrastructure (`tofu apply`, 15~20분)

```
tofu apply
  ├─ Resource Groups (common, mgmt, app1, app2)
  ├─ VNet + Subnets + NSG
  ├─ VNet Peering (mgmt↔app1, mgmt↔app2, app1↔app2)
  ├─ Azure Key Vault + RBAC
  ├─ Azure Monitor Workspace
  ├─ Log Analytics Workspace
  ├─ Azure Backup Vault
  ├─ AKS Clusters (mgmt, app1, app2)
  │    ├─ networkDataplane: cilium
  │    ├─ monitor_metrics {}
  │    ├─ oms_agent {}
  │    ├─ key_vault_secrets_provider {}
  │    ├─ System Node Pool (Regular)
  │    ├─ Worker Node Pool (Spot)
  │    └─ Node Auto-Provisioning (Karpenter)
  └─ Managed Identity + Workload Identity Federation
                    ↓
          az aks get-credentials (kubeconfig 생성)
```

> Phase 1에서 Managed Cilium, Prometheus, Container Insights, Key Vault CSI, Karpenter가 자동 활성화됨.

### 11.4 Phase 2: Addon Installation (`bash addons/install.sh --all`, 10~15분)

| # | 스크립트 | 대상 | 의존성 |
|---|---------|------|--------|
| 0 | `install-priority-classes.sh` | 전 클러스터 | kubeconfig |
| 1 | `enable-hubble.sh` | 전 클러스터 | AKS 생성 |
| 2 | `install-gateway-api.sh` | 전 클러스터 | Cilium |
| 3 | `install-cert-manager.sh` | 전 클러스터 | Gateway API |
| 4 | `enable-istio-addon.sh` | mgmt + app1 | cert-manager |
| 5 | `install-kiali.sh` | mgmt + app1 | Istio |
| 6 | `enable-flux-gitops.sh` | 전 클러스터 | AKS 생성 |
| 7 | `install-kyverno.sh` | app1/app2 | Flux |
| 8 | `enable-defender.sh` | 전 클러스터 | AKS 생성 |
| 9 | `enable-aks-backup.sh` | 전 클러스터 | Backup Vault |
| - | `scripts/verify-clusters.sh` | 검증 | 전체 완료 |

```bash
bash addons/install.sh --all

# 카테고리별
bash addons/install.sh --category networking    # hubble, gateway-api, istio
bash addons/install.sh --category security      # kyverno, defender
bash addons/install.sh --category gitops        # flux
bash addons/install.sh --category backup        # aks-backup
```

### 11.5 비용 관리

```bash
# 일시 정지 (비사용 시간)
az aks stop -g rg-k8s-demo-mgmt -n aks-mgmt --no-wait
az aks stop -g rg-k8s-demo-app1 -n aks-app1 --no-wait
az aks stop -g rg-k8s-demo-app2 -n aks-app2 --no-wait

# 재시작
az aks start -g rg-k8s-demo-mgmt -n aks-mgmt --no-wait
az aks start -g rg-k8s-demo-app1 -n aks-app1 --no-wait
az aks start -g rg-k8s-demo-app2 -n aks-app2 --no-wait

# 전체 삭제 (비용 $0)
tofu destroy
```

---

## 12. 서비스 접근 레퍼런스

### 12.1 Azure Portal

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

### 12.2 Port-Forward (클러스터 내 컴포넌트)

| 서비스 | Namespace | Port | URL |
|--------|-----------|------|-----|
| Kiali | istio-system | 20001 | http://localhost:20001/kiali |
| Hubble UI | kube-system | 12000 | http://localhost:12000 |

### 12.3 LoadBalancer (Azure LB Public IP)

| 서비스 | Namespace | Port |
|--------|-----------|------|
| Istio Ingress Gateway | istio-system | 80/443 |

### 12.4 자격증명

```bash
# AKS kubeconfig
az aks get-credentials -g rg-k8s-demo-mgmt -n aks-mgmt
az aks get-credentials -g rg-k8s-demo-app1 -n aks-app1
az aks get-credentials -g rg-k8s-demo-app2 -n aks-app2

# Key Vault 시크릿
az keyvault secret list --vault-name kv-k8s-demo -o table
az keyvault secret show --vault-name kv-k8s-demo --name <secret-name> --query value -o tsv
```

> 모든 Azure 관리형 서비스는 Entra ID 인증. 별도 패스워드 관리 불필요.
