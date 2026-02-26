# Azure Kubernetes 아키텍처 다이어그램

> **ARCHITECTURE.md** 보조 문서 — Mermaid 기반 시각화
> **최종 수정일**: 2026-02-26

---

## 목차

1. [전체 인프라 구성](#1-전체-인프라-구성)
2. [Azure Resource Group 구조](#2-azure-resource-group-구조)
3. [네트워크 토폴로지](#3-네트워크-토폴로지)
4. [트래픽 플로우 — 외부 요청](#4-트래픽-플로우--외부-요청)
5. [트래픽 플로우 — 내부 서비스 간 통신](#5-트래픽-플로우--내부-서비스-간-통신)
6. [관찰성 데이터 흐름](#6-관찰성-데이터-흐름)
7. [시크릿 & 인증 흐름](#7-시크릿--인증-흐름)
8. [GitOps 배포 흐름](#8-gitops-배포-흐름)
9. [백업 & DR 흐름](#9-백업--dr-흐름)
10. [Spot Eviction & 복구 흐름](#10-spot-eviction--복구-흐름)
11. [보안 계층 구조](#11-보안-계층-구조)
12. [설치 워크플로우](#12-설치-워크플로우)

---

## 1. 전체 인프라 구성

> **대상**: 전체 이해관계자 (인프라 엔지니어, 개발자, 매니저)
>
> 3개 AKS 클러스터(mgmt/app1/app2)와 공유 Azure 리소스의 전체 배치를 보여줍니다.
> 핵심 포인트: 모든 클러스터가 공통 리소스(Key Vault, Monitor, Backup Vault)를 **공유**하며,
> 관찰성/백업 데이터는 클러스터 외부에 저장되어 클러스터 독립적으로 보존됩니다.

```mermaid
graph TB
    subgraph Azure["Azure Cloud (Korea Central)"]

        subgraph Common["rg-k8s-demo-common"]
            VNet["VNet 10.0.0.0/8"]
            KV["Azure Key Vault"]
            MON["Azure Monitor Workspace<br/>(Managed Prometheus)"]
            LAW["Log Analytics Workspace"]
            AI["Application Insights"]
            BV["Azure Backup Vault"]
            DNS["Azure DNS Zone"]
            ACR["Azure Container Registry<br/>(Basic)"]
        end

        subgraph MGMT["rg-k8s-demo-mgmt"]
            subgraph AKS_MGMT["AKS mgmt"]
                MGMT_SYS["System Pool<br/>D2s_v5 (Regular)"]
                MGMT_SPOT["Worker Pool<br/>D2s_v5 (Spot)"]
                MGMT_CP["Managed<br/>Control Plane"]
            end
        end

        subgraph APP1["rg-k8s-demo-app1"]
            subgraph AKS_APP1["AKS app1"]
                APP1_SYS["System Pool<br/>D2s_v5 (Regular)"]
                APP1_SPOT["Worker Pool<br/>D2s_v5 (Spot)"]
                APP1_CP["Managed<br/>Control Plane"]
            end
        end

        subgraph APP2["rg-k8s-demo-app2"]
            subgraph AKS_APP2["AKS app2"]
                APP2_SYS["System Pool<br/>D2s_v5 (Regular)"]
                APP2_SPOT["Worker Pool<br/>D2s_v5 (Spot)"]
                APP2_CP["Managed<br/>Control Plane"]
            end
        end

        ALB_MGMT["Azure LB<br/>(mgmt)"]
        ALB_APP1["Azure LB<br/>(app1)"]

        AKS_MGMT --- ALB_MGMT
        AKS_APP1 --- ALB_APP1

        AKS_MGMT -.->|metrics/logs| MON
        AKS_APP1 -.->|metrics/logs| MON
        AKS_APP2 -.->|metrics/logs| MON
        AKS_MGMT -.->|logs| LAW
        AKS_APP1 -.->|logs| LAW
        AKS_APP2 -.->|logs| LAW
        AKS_MGMT -.->|secrets| KV
        AKS_APP1 -.->|secrets| KV
        AKS_APP2 -.->|secrets| KV
        AKS_MGMT -.->|backup| BV
        AKS_APP1 -.->|backup| BV
        AKS_APP2 -.->|backup| BV
        AKS_MGMT -.->|pull image| ACR
        AKS_APP1 -.->|pull image| ACR
        AKS_APP2 -.->|pull image| ACR
    end

    User["User / Browser"]
    User -->|HTTPS| ALB_MGMT
    User -->|HTTPS| ALB_APP1

    IaC["OpenTofu"]
    IaC -->|tofu apply| Azure
```

---

## 2. Azure Resource Group 구조

> **대상**: 인프라 엔지니어, 비용 관리자
>
> 4개 Resource Group 간 리소스 소속과 의존 관계를 보여줍니다.
> 핵심 포인트: `rg-k8s-demo-common`에 공유 리소스를 집중하여
> 클러스터별 RG를 독립적으로 생성/삭제할 수 있는 구조입니다.

```mermaid
graph LR
    subgraph rg-common["rg-k8s-demo-common"]
        VNet["VNet + Subnets + NSG"]
        KV["Key Vault"]
        MON["Monitor Workspace"]
        LAW["Log Analytics"]
        AI["App Insights"]
        BV["Backup Vault"]
        DNS["DNS Zone"]
        ACR["ACR (Basic)"]
    end

    subgraph rg-mgmt["rg-k8s-demo-mgmt"]
        AKS_M["AKS mgmt"]
        MI_M["Managed Identity"]
    end

    subgraph rg-app1["rg-k8s-demo-app1"]
        AKS_A1["AKS app1"]
        MI_A1["Managed Identity"]
    end

    subgraph rg-app2["rg-k8s-demo-app2"]
        AKS_A2["AKS app2"]
        MI_A2["Managed Identity"]
    end

    AKS_M -->|Subnet| VNet
    AKS_A1 -->|Subnet| VNet
    AKS_A2 -->|Subnet| VNet

    MI_M -->|RBAC| KV
    MI_A1 -->|RBAC| KV
    MI_A2 -->|RBAC| KV

    AKS_M -->|metrics| MON
    AKS_A1 -->|metrics| MON
    AKS_A2 -->|metrics| MON

    AKS_M -->|backup| BV
    AKS_A1 -->|backup| BV
    AKS_A2 -->|backup| BV

    MI_M -->|AcrPull| ACR
    MI_A1 -->|AcrPull| ACR
    MI_A2 -->|AcrPull| ACR
```

---

## 3. 네트워크 토폴로지

> **대상**: 인프라/네트워크 엔지니어
>
> 단일 VNet 내 3개 서브넷 배치와 Azure CNI Overlay + Managed Cilium 계층을 보여줍니다.
> 핵심 포인트: 같은 VNet 내 서브넷이므로 별도 Peering 없이 통신 가능하며,
> Pod CIDR은 Overlay로 VNet 주소와 분리되어 IP 고갈 걱정이 없습니다.

```mermaid
graph TB
    subgraph VNet["VNet 10.0.0.0/8"]
        subgraph SubMgmt["mgmt Subnet 10.1.0.0/16"]
            MGMT_NODES["mgmt Nodes"]
        end
        subgraph SubApp1["app1 Subnet 10.2.0.0/16"]
            APP1_NODES["app1 Nodes"]
        end
        subgraph SubApp2["app2 Subnet 10.3.0.0/16"]
            APP2_NODES["app2 Nodes"]
        end
    end

    SubMgmt <-->|"동일 VNet 내 직접 통신"| SubApp1
    SubMgmt <-->|"동일 VNet 내 직접 통신"| SubApp2
    SubApp1 <-->|"동일 VNet 내 직접 통신"| SubApp2

    NSG_M["NSG (mgmt)"] --- SubMgmt
    NSG_A1["NSG (app1)"] --- SubApp1
    NSG_A2["NSG (app2)"] --- SubApp2

    subgraph Overlay["Azure CNI Overlay (각 클러스터)"]
        direction LR
        POD_CIDR["Pod CIDR<br/>(자동 할당, VNet과 분리)"]
        SVC_CIDR["Service CIDR<br/>(자동 할당)"]
    end

    subgraph Cilium["Managed Cilium (각 클러스터)"]
        direction LR
        EBPF["eBPF 데이터플레인"]
        NP["Cilium NetworkPolicy"]
        HUB["Hubble (관찰성)"]
    end

    VNet --> Overlay
    Overlay --> Cilium
```

---

## 4. 트래픽 플로우 — 외부 요청

> **대상**: 개발자, 인프라 엔지니어
>
> 외부 사용자 요청이 DNS → Azure LB → Istio Ingress Gateway → VirtualService → Pod까지
> 도달하는 전체 경로를 시퀀스로 보여줍니다.
> 핵심 포인트: TLS Termination은 Istio Gateway에서 수행하며, cert-manager가
> Let's Encrypt 인증서를 자동 갱신합니다. LB는 L4 TCP 포워딩만 담당합니다.

```mermaid
sequenceDiagram
    actor User as User / Browser
    participant DNS as Azure DNS
    participant ALB as Azure Load Balancer
    participant IGW as Istio Ingress Gateway
    participant VS as VirtualService (L7 라우팅)
    participant SVC as K8s Service (ClusterIP)
    participant POD as App Pod (+ Istio Sidecar)

    User->>DNS: app.example.com
    DNS-->>User: Azure LB Public IP
    User->>ALB: HTTPS :443
    ALB->>IGW: TCP Forward (NodePort)
    IGW->>IGW: TLS Termination (cert-manager 인증서)
    IGW->>VS: Host/Path 매칭
    VS->>SVC: 라우팅 규칙 적용 (retry, timeout, weight)
    SVC->>POD: Cilium eBPF L3/L4 로드밸런싱
    POD->>POD: Istio Sidecar (mTLS 복호화)
    POD-->>User: HTTP Response
```

---

## 5. 트래픽 플로우 — 내부 서비스 간 통신

> **대상**: 개발자, 플랫폼 엔지니어
>
> Pod 간 통신에서 Managed Cilium(L3/L4)과 Istio Sidecar(L7)의 역할 분담을 보여줍니다.
> 핵심 포인트: Cilium eBPF가 패킷 라우팅과 NetworkPolicy를 처리하고,
> Envoy Sidecar가 mTLS 암호화와 L7 정책(retry, timeout, AuthorizationPolicy)을 처리합니다.

```mermaid
sequenceDiagram
    participant A as Pod A (+ Sidecar)
    participant PA as Envoy Proxy A
    participant CIL as Managed Cilium (eBPF)
    participant PB as Envoy Proxy B
    participant B as Pod B (+ Sidecar)

    A->>PA: Outbound Request
    PA->>PA: mTLS 암호화
    PA->>CIL: L3/L4 라우팅 (eBPF)
    CIL->>CIL: NetworkPolicy 검사
    CIL->>PB: Packet Forward
    PB->>PB: mTLS 복호화 + AuthorizationPolicy 검사
    PB->>B: Request 전달
    B-->>A: Response (역순)
```

### 계층별 역할 요약

```mermaid
graph LR
    subgraph L3_L4["L3/L4 (Managed Cilium)"]
        ROUTE["패킷 라우팅"]
        LB["로드밸런싱"]
        NP["NetworkPolicy"]
        KP["kube-proxy 대체"]
    end

    subgraph L7["L7 (AKS Istio Add-on)"]
        MTLS["mTLS 암호화"]
        RETRY["Retry / Timeout"]
        CANARY["Canary / Weight"]
        AUTHZ["AuthorizationPolicy"]
    end

    L3_L4 --> L7
```

---

## 6. 관찰성 데이터 흐름

> **대상**: SRE, 개발자, 인프라 엔지니어
>
> 메트릭/로그/트레이스 3종 데이터가 클러스터에서 Azure Monitor로 수집되는 경로와
> Azure Portal에서의 시각화 방법을 보여줍니다.
> 핵심 포인트: 모든 관찰성 데이터는 클러스터 외부(Azure Monitor)에 저장되므로
> 클러스터 삭제/장애 시에도 데이터가 보존됩니다.

```mermaid
graph TB
    subgraph Cluster["AKS Cluster (mgmt / app1 / app2)"]
        CIA["Container Insights Agent<br/>(관리형 DaemonSet)"]
        APP["App Pod<br/>(OTel SDK)"]
        CILIUM["Cilium + Hubble"]
        KIALI["Kiali<br/>(mgmt, app1만)"]
    end

    subgraph AzureMonitor["Azure Monitor (클러스터 외부)"]
        PROM["Managed Prometheus<br/>(Azure Monitor Workspace)"]
        LOG["Log Analytics Workspace"]
        APPINS["Application Insights"]
    end

    subgraph Portal["Azure Portal"]
        GRAF["내장 Grafana 대시보드"]
        KQL["KQL 쿼리 에디터"]
        APPMAP["Application Map"]
        INSIGHTS["AKS Insights 블레이드"]
    end

    CIA -->|"Prometheus 메트릭<br/>(remote write)"| PROM
    CIA -->|"컨테이너 로그<br/>(stdout/stderr)"| LOG
    APP -->|"OTel 트레이스<br/>(OTLP)"| APPINS
    CILIUM -->|"네트워크 플로우"| KIALI

    PROM --> GRAF
    PROM --> INSIGHTS
    LOG --> KQL
    APPINS --> APPMAP

    style AzureMonitor fill:#e6f3ff,stroke:#0078d4
    style Portal fill:#fff3e6,stroke:#ff8c00
```

### 데이터 보존 정책

```mermaid
graph LR
    PROM["Managed Prometheus<br/>18개월"] -->|"만료 후"| DEL1["자동 삭제"]
    LOG["Log Analytics<br/>30일 (Interactive)"] -->|"아카이브"| ARCH["12년 (Archive Tier)"]
    APPINS["Application Insights<br/>90일"] -->|"만료 후"| DEL2["자동 삭제"]
    BACKUP["Backup Vault<br/>7일 (시연)"] -->|"만료 후"| DEL3["자동 삭제"]
```

---

## 7. 시크릿 & 인증 흐름

> **대상**: 보안 엔지니어, 개발자
>
> Pod 시작 시 Key Vault CSI Driver를 통한 시크릿 마운트 과정과
> Workload Identity의 Token Exchange 메커니즘을 보여줍니다.
> 핵심 포인트: 시크릿은 etcd에 저장되지 않고 Volume Mount로 직접 주입되며,
> 2분 간격 Auto-rotation으로 Key Vault 변경사항이 자동 반영됩니다.

```mermaid
sequenceDiagram
    participant POD as App Pod
    participant CSI as Key Vault CSI Driver
    participant WI as Workload Identity
    participant AAD as Entra ID
    participant KV as Azure Key Vault

    Note over POD,KV: Pod 시작 시 시크릿 마운트
    POD->>CSI: Volume Mount 요청
    CSI->>WI: Federated Token 요청
    WI->>AAD: Token Exchange (OIDC)
    AAD-->>WI: Access Token
    WI-->>CSI: Access Token
    CSI->>KV: GET Secret (Bearer Token)
    KV-->>CSI: Secret Value
    CSI-->>POD: /mnt/secrets/에 파일 마운트

    Note over CSI,KV: 2분 간격 Auto-rotation
    loop 매 2분
        CSI->>KV: 시크릿 변경 확인
        KV-->>CSI: 변경 시 새 값 반환
        CSI-->>POD: Volume 파일 갱신
    end
```

### Workload Identity 연동 맵

```mermaid
graph TB
    subgraph AKS["AKS Clusters"]
        CM["cert-manager SA"]
        CSID["Key Vault CSI Driver SA"]
        BKUP["AKS Backup Extension SA"]
        CIAGENT["Container Insights Agent SA"]
        FLUX["Flux v2 SA"]
    end

    subgraph Entra["Entra ID"]
        MI_CM["Managed Identity<br/>(cert-manager)"]
        MI_CSI["Managed Identity<br/>(CSI Driver)"]
        MI_BK["Managed Identity<br/>(Backup)"]
        MI_MON["Managed Identity<br/>(Monitoring)"]
    end

    subgraph Resources["Azure Resources"]
        KV["Key Vault"]
        BV["Backup Vault"]
        MW["Monitor Workspace"]
        ACR2["ACR"]
        DNSZ["DNS Zone"]
        GIT["GitHub Repo"]
    end

    CM -->|"Federated Token"| MI_CM
    CSID -->|"Federated Token"| MI_CSI
    BKUP -->|"Federated Token"| MI_BK
    CIAGENT -->|"Federated Token"| MI_MON

    MI_CM -->|"Certificates Get/List"| KV
    MI_CSI -->|"Secrets Get/List"| KV
    MI_BK -->|"Backup Contributor"| BV
    MI_MON -->|"Metrics Publisher"| MW
    MI_CM -->|"DNS TXT write"| DNSZ
    FLUX -->|"Git Pull"| GIT

    subgraph Kubelet["Kubelet Identity (각 클러스터)"]
        KI["Kubelet Managed Identity"]
    end

    KI -->|"AcrPull"| ACR2
```

---

## 8. GitOps 배포 흐름

> **대상**: 개발자, DevOps 엔지니어
>
> Developer → GitHub → Flux v2 → Kubernetes 배포 파이프라인과
> 클러스터별 독립 Flux 인스턴스의 멀티클러스터 구조를 보여줍니다.
> 핵심 포인트: 각 클러스터에 독립된 Flux가 동작하며, Repository의 `base/`에서
> 공통 manifest를 상속하고 `clusters/<name>/`에서 클러스터별 오버라이드를 적용합니다.

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant GH as GitHub Repository
    participant FLUX as Flux v2 (AKS 애드온)
    participant K8S as Kubernetes API
    participant POD as Pods

    Dev->>GH: git push (manifest 변경)
    Note over FLUX: 주기적 Git Poll (1분)
    FLUX->>GH: git pull (변경 감지)
    GH-->>FLUX: 새 manifest
    FLUX->>FLUX: Kustomize / Helm 렌더링
    FLUX->>K8S: kubectl apply (reconcile)
    K8S->>POD: Rolling Update
    FLUX->>FLUX: Health Check
    Note over Dev: Azure Portal → AKS → GitOps에서 상태 확인
```

### GitOps 멀티클러스터 구조

```mermaid
graph TB
    GH["GitHub Repository"]

    subgraph FluxInstances["Flux v2 (클러스터별 독립)"]
        F_MGMT["Flux (mgmt)<br/>path: clusters/mgmt/"]
        F_APP1["Flux (app1)<br/>path: clusters/app1/"]
        F_APP2["Flux (app2)<br/>path: clusters/app2/"]
    end

    subgraph Repo["Repository 구조"]
        BASE["base/<br/>(공통 manifest)"]
        C_MGMT["clusters/mgmt/<br/>(mgmt 전용)"]
        C_APP1["clusters/app1/<br/>(app1 전용)"]
        C_APP2["clusters/app2/<br/>(app2 전용)"]
    end

    GH --> F_MGMT
    GH --> F_APP1
    GH --> F_APP2

    F_MGMT --> C_MGMT
    F_APP1 --> C_APP1
    F_APP2 --> C_APP2
    C_MGMT --> BASE
    C_APP1 --> BASE
    C_APP2 --> BASE
```

---

## 9. 백업 & DR 흐름

> **대상**: 인프라 엔지니어, SRE
>
> Azure Backup Vault를 통한 일일 스냅샷 정책과 3가지 복원 시나리오를 보여줍니다.
> 핵심 포인트: Spot Eviction은 Karpenter가 자동 복구(~5분)하고,
> 클러스터 장애 시 `tofu apply` + Backup 복원으로 ~30분 내 복구 가능합니다.

```mermaid
graph TB
    subgraph AKS["AKS Cluster"]
        EXT["Backup Extension"]
        K8S_RES["K8s Resources<br/>(Deployments, Services...)"]
        PV["Persistent Volumes<br/>(Azure Disk CSI)"]
    end

    subgraph BackupVault["Azure Backup Vault (rg-common)"]
        SNAP["Backup Snapshots"]
        POLICY["Backup Policy<br/>daily 02:00 UTC / 7일 보존"]
    end

    POLICY -->|trigger| EXT
    EXT -->|snapshot| K8S_RES
    EXT -->|snapshot| PV
    K8S_RES --> SNAP
    PV --> SNAP

    subgraph Restore["복원 시나리오"]
        R1["Spot Eviction<br/>→ Karpenter 자동 복구 (~5분)"]
        R2["클러스터 장애<br/>→ tofu apply + Backup 복원 (~30분)"]
        R3["리전 장애<br/>→ Cross-Region Restore (~1시간)"]
    end

    SNAP -.->|복원| R2
    SNAP -.->|GRS 복제| R3
```

---

## 10. Spot Eviction & 복구 흐름

> **대상**: 인프라 엔지니어, SRE
>
> Spot VM 퇴거 발생 시 Karpenter(NAP)의 자동 복구 시퀀스를 보여줍니다.
> 핵심 포인트: Spot 용량 부족 시 On-Demand로 자동 Fallback하며,
> PodDisruptionBudget과 TopologySpreadConstraints로 동시 퇴거 영향을 최소화합니다.

```mermaid
sequenceDiagram
    participant AZ as Azure Platform
    participant NODE as Spot VM Node
    participant KARP as Karpenter (NAP)
    participant SCHED as Kubernetes Scheduler
    participant POD as Evicted Pods

    AZ->>NODE: Eviction Notice (30초 전)
    NODE->>POD: SIGTERM 전파
    POD->>POD: Graceful Shutdown
    AZ->>NODE: VM Delete
    Note over KARP: Pending Pod 감지
    KARP->>KARP: NodePool CRD 조건 확인<br/>(sku-family: D, capacity: spot/on-demand)
    KARP->>AZ: Spot VM 프로비저닝 요청
    alt Spot 용량 있음
        AZ-->>KARP: 새 Spot VM 생성
    else Spot 용량 없음
        AZ-->>KARP: 실패
        KARP->>AZ: On-Demand VM 프로비저닝
        AZ-->>KARP: On-Demand VM 생성
    end
    KARP->>SCHED: 새 노드 Ready
    SCHED->>POD: Pod 재스케줄링
    POD->>POD: 정상 기동

    Note over POD: PDB로 동시 퇴거 제한<br/>TopologySpread로 노드 분산
```

---

## 11. 보안 계층 구조

> **대상**: 보안 엔지니어, 아키텍트
>
> ID/접근제어 → 워크로드 정책 → 네트워크 → 시크릿 → 런타임 → 취약점 관리의
> 6계층 보안 모델(Defense in Depth)을 보여줍니다.
> 핵심 포인트: 각 계층은 독립적으로 동작하여 한 계층이 뚫려도
> 다음 계층에서 차단하는 다중 방어 구조입니다.

```mermaid
graph TB
    subgraph L1["L1 — ID & 접근 제어"]
        ENTRA["Entra ID<br/>(Azure AD)"]
        RBAC["AKS RBAC"]
        MI["Managed Identity"]
        WI["Workload Identity"]
        AUTHIP["API Server<br/>Authorized IP Ranges"]
    end

    subgraph L2["L2 — 워크로드 정책"]
        PSA["Pod Security Admission<br/>(baseline enforce)"]
        KYV["Kyverno Enforce<br/>(app 클러스터만)"]
    end

    subgraph L3["L3 — 네트워크 보안"]
        NSG["Azure NSG<br/>(서브넷 레벨)"]
        CNP["Cilium NetworkPolicy<br/>(Pod 레벨)"]
    end

    subgraph L4["L4 — 시크릿 보호"]
        KVCSI["Key Vault CSI Driver<br/>(etcd 미저장)"]
        ROT["Auto-rotation<br/>(2분 폴링)"]
    end

    subgraph L5["L5 — 런타임 보안"]
        DEF_RT["Defender Runtime<br/>위협 탐지"]
        DEF_MAL["Defender Malware<br/>악성코드 감지"]
    end

    subgraph L6["L6 — 취약점 관리"]
        DEF_IMG["Defender Image Scan<br/>(레지스트리 + 실행중)"]
        DEF_GATE["Deployment Gating<br/>(취약 이미지 차단)"]
    end

    L1 --> L2 --> L3 --> L4 --> L5 --> L6

    style L1 fill:#e8f5e9,stroke:#2e7d32
    style L2 fill:#e3f2fd,stroke:#1565c0
    style L3 fill:#fff3e0,stroke:#e65100
    style L4 fill:#fce4ec,stroke:#c62828
    style L5 fill:#f3e5f5,stroke:#6a1b9a
    style L6 fill:#efebe9,stroke:#4e342e
```

---

## 12. 설치 워크플로우

> **대상**: 인프라 엔지니어
>
> Phase 1(`tofu apply`, 15~20분)과 Phase 2(`addons/install.sh`, 10~15분)의
> 2단계 설치 과정과 리소스 간 의존 관계를 보여줍니다.
> 핵심 포인트: Phase 1에서 인프라와 AKS 클러스터를 생성하면
> Managed Cilium/Prometheus/Karpenter 등이 자동 활성화되고,
> Phase 2에서 Istio/Flux/Kyverno 등 애드온을 순차 설치합니다.

```mermaid
graph TB
    subgraph Phase1["Phase 1: tofu apply (15~20분)"]
        direction TB
        P1_1["Resource Groups"] --> P1_2["VNet + Subnets + NSG"]
        P1_2 --> P1_3["DNS Zone"]
        P1_2 --> P1_4["Key Vault"]
        P1_2 --> P1_5["Monitor Workspace"]
        P1_2 --> P1_6["Log Analytics"]
        P1_2 --> P1_7["Backup Vault"]
        P1_2 --> P1_ACR["ACR (Basic)"]
        P1_3 --> P1_8["AKS Clusters (x3)"]
        P1_ACR --> P1_8
        P1_4 --> P1_8
        P1_5 --> P1_8
        P1_6 --> P1_8
        P1_8 --> P1_9["Managed Identity +<br/>Workload Identity"]
        P1_8 --> P1_AUTO["자동 활성화:<br/>Managed Cilium<br/>Managed Prometheus<br/>Container Insights<br/>Key Vault CSI<br/>Karpenter"]
    end

    subgraph Phase2["Phase 2: addons/install.sh (10~15분)"]
        direction TB
        P2_1["priority-classes"] --> P2_2["enable-hubble"]
        P2_2 --> P2_3["gateway-api CRD"]
        P2_3 --> P2_4["cert-manager"]
        P2_4 --> P2_5["Istio Add-on"]
        P2_5 --> P2_6["Kiali"]
        P2_1 --> P2_7["Flux v2 GitOps"]
        P2_7 --> P2_8["Kyverno<br/>(app1/app2)"]
        P2_1 --> P2_9["Defender"]
        P2_1 --> P2_10["AKS Backup"]
    end

    Phase1 --> Phase2

    style Phase1 fill:#e3f2fd,stroke:#1565c0
    style Phase2 fill:#e8f5e9,stroke:#2e7d32
    style P1_AUTO fill:#fff9c4,stroke:#f9a825
```
