# Azure Kubernetes 아키텍처 다이어그램

> **ARCHITECTURE.md** 보조 문서 — Mermaid 기반 시각화
> **최종 수정일**: 2026-02-27

---

## 목차

1. [전체 인프라 구성](#1-전체-인프라-구성)
2. [Azure Resource Group 구조](#2-azure-resource-group-구조)
3. [네트워크 토폴로지](#3-네트워크-토폴로지)
4. [트래픽 플로우](#4-트래픽-플로우)
5. [보안 계층 구조](#5-보안-계층-구조)
6. [시크릿 & 인증 흐름](#6-시크릿--인증-흐름)
7. [관찰성 데이터 흐름](#7-관찰성-데이터-흐름)
8. [GitOps 배포 흐름](#8-gitops-배포-흐름)
9. [Spot Eviction & 복구 흐름](#9-spot-eviction--복구-흐름)
10. [백업 & DR 흐름](#10-백업--dr-흐름)
11. [설치 워크플로우](#11-설치-워크플로우)
12. [Korea Central AZ 아키텍처](#12-korea-central-availability-zone-아키텍처)
13. [관리자 접근 흐름 (Bastion)](#13-관리자-접근-흐름-bastion)

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
            subgraph AKS_MGMT["AKS mgmt (Standard Tier, Zone 1/2/3)"]
                MGMT_SYS["System Pool<br/>D2s_v5 × 3 (Regular, AZ)"]
                MGMT_IGW["Ingress Pool<br/>D2s_v5 × 3 (Regular, AZ)"]
                MGMT_SPOT["Worker Pool<br/>D2s_v5 (Spot, AZ)"]
                MGMT_CP["Managed<br/>Control Plane"]
            end
            BASTION["Azure Bastion<br/>(PaaS, Basic)"]
            JUMPVM["Jump VM<br/>(B2s, private IP)"]
        end

        subgraph APP1["rg-k8s-demo-app1"]
            subgraph AKS_APP1["AKS app1 (Standard Tier, Zone 1/2/3)"]
                APP1_SYS["System Pool<br/>D2s_v5 × 3 (Regular, AZ)"]
                APP1_IGW["Ingress Pool<br/>D2s_v5 × 3 (Regular, AZ)"]
                APP1_SPOT["Worker Pool<br/>D2s_v5 (Spot, AZ)"]
                APP1_CP["Managed<br/>Control Plane"]
            end
        end

        subgraph APP2["rg-k8s-demo-app2"]
            subgraph AKS_APP2["AKS app2 (Standard Tier, Zone 1/2/3)"]
                APP2_SYS["System Pool<br/>D2s_v5 × 3 (Regular, AZ)"]
                APP2_SPOT["Worker Pool<br/>D2s_v5 (Spot, AZ)"]
                APP2_CP["Managed<br/>Control Plane"]
            end
        end

        ALB_MGMT["Azure LB<br/>(mgmt)"]
        ALB_APP1["Azure LB<br/>(app1)"]

        AKS_MGMT --- ALB_MGMT
        AKS_APP1 --- ALB_APP1
        %% app2: Ingress 미배포 — 외부 LB 없음 (ARCHITECTURE.md §5.4 참조)

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
    %% app2 Ingress 미배포 — User 직접 접근 없음

    Admin["관리자"]
    Admin -->|"HTTPS (Bastion Portal)"| BASTION
    BASTION -->|"SSH (private)"| JUMPVM
    JUMPVM -->|"kubectl (VNet 내부)"| AKS_MGMT
    JUMPVM -->|"kubectl (VNet 내부)"| AKS_APP1
    JUMPVM -->|"kubectl (VNet 내부)"| AKS_APP2

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
        BAST["Azure Bastion"]
        JVM["Jump VM (private)"]
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
> 클러스터별 독립 VNet과 VNet Peering, Azure CNI Overlay + Managed Cilium 계층을 보여줍니다.
> 핵심 포인트: 각 클러스터는 **별도 VNet**(10.1~10.3.0.0/16)을 가지며
> **VNet Peering**으로 상호 연결됩니다. Pod CIDR은 Overlay로 VNet 주소와 분리됩니다.

```mermaid
graph TB
    subgraph mgmtVNet["mgmt VNet 10.1.0.0/16"]
        MGMT_NODES["mgmt Nodes"]
        NSG_M["NSG (mgmt)"]
        BASTION_SUB["AzureBastionSubnet<br/>10.1.100.0/26"]
        JUMP_NODE["Jump VM (private IP)"]
    end

    subgraph app1VNet["app1 VNet 10.2.0.0/16"]
        APP1_NODES["app1 Nodes"]
        NSG_A1["NSG (app1)"]
    end

    subgraph app2VNet["app2 VNet 10.3.0.0/16"]
        APP2_NODES["app2 Nodes"]
        NSG_A2["NSG (app2)"]
    end

    mgmtVNet <-->|"VNet Peering"| app1VNet
    mgmtVNet <-->|"VNet Peering"| app2VNet
    app1VNet <-->|"VNet Peering"| app2VNet

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

    mgmtVNet --> Overlay
    app1VNet --> Overlay
    app2VNet --> Overlay
    Overlay --> Cilium
```

---

## 4. 트래픽 플로우

### 4.1 외부 요청 흐름

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

### 4.2 내부 서비스 간 통신

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

## 5. 보안 계층 구조

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
        PRIVATE["AKS Private Cluster<br/>(공개 엔드포인트 없음)"]
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

## 6. 시크릿 & 인증 흐름

> **대상**: 보안 엔지니어, 개발자
>
> TLS 인증서 발급(cert-manager) → Key Vault 동기화(ESO PushSecret) → Pod 마운트(CSI Driver) → 자동 재시작(Stakater Reloader)의
> 완전 자동화 라이프사이클과 일반 시크릿 마운트 흐름을 보여줍니다.
> 핵심 포인트: Private Key가 etcd에 장기 보관되지 않고 Key Vault에만 저장되며,
> 인증서 갱신 시 수동 개입 없이 Pod가 자동으로 재시작됩니다.

### TLS 인증서 자동 갱신 라이프사이클

```mermaid
sequenceDiagram
    participant CM as cert-manager
    participant LE as Let's Encrypt
    participant DNS as Azure DNS
    participant KS as K8s Secret
    participant ESO as ESO PushSecret
    participant KV as Azure Key Vault
    participant CSI as Key Vault CSI Driver
    participant RL as Stakater Reloader
    participant IGW as Istio Ingress Gateway

    Note over CM,IGW: 인증서 발급 (최초 또는 만료 30일 전 자동)
    CM->>LE: ACME DNS-01 챌린지 요청
    CM->>DNS: TXT 레코드 생성
    LE-->>CM: 챌린지 검증 완료
    CM->>KS: tls.crt / tls.key 저장 (임시)
    CM->>ESO: PushSecret 트리거
    ESO->>KV: tls.crt / tls.key 동기화 (Private Key etcd 탈출)

    Note over CSI,IGW: Pod 마운트 및 자동 갱신 반영
    loop 매 2분 (Auto-rotation)
        CSI->>KV: 인증서 변경 확인
        KV-->>CSI: 변경 시 새 인증서 반환
        CSI-->>IGW: Volume 파일 갱신
        CSI->>RL: 변경 감지 알림
        RL->>IGW: Rolling Restart 트리거
        IGW->>IGW: 새 인증서로 무중단 재시작
    end
```

### 일반 시크릿 마운트 흐름 (앱 워크로드)

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
        ESO_SA["ESO SA<br/>(PushSecret)"]
        BKUP["AKS Backup Extension SA"]
        CIAGENT["Container Insights Agent SA"]
        FLUX["Flux v2 SA"]
        RL["Stakater Reloader"]
    end

    subgraph Entra["Entra ID"]
        MI_CM["Managed Identity<br/>(cert-manager)"]
        MI_CSI["Managed Identity<br/>(CSI Driver)"]
        MI_ESO["Managed Identity<br/>(ESO)"]
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
    ESO_SA -->|"Federated Token"| MI_ESO
    BKUP -->|"Federated Token"| MI_BK
    CIAGENT -->|"Federated Token"| MI_MON

    MI_CM -->|"DNS TXT write"| DNSZ
    MI_CM -->|"Certificates Get/List"| KV
    MI_ESO -->|"Secrets Set (PushSecret)"| KV
    MI_CSI -->|"Secrets Get/List"| KV
    MI_BK -->|"Backup Contributor"| BV
    MI_MON -->|"Metrics Publisher"| MW
    FLUX -->|"SSH Deploy Key<br/>(K8s Secret, flux-system NS)"| GIT
    RL -->|"Watch Deployments<br/>(RBAC: patch)"| AKS

    subgraph Kubelet["Kubelet Identity (각 클러스터)"]
        KI["Kubelet Managed Identity"]
    end

    KI -->|"AcrPull"| ACR2
```

---

## 7. 관찰성 데이터 흐름

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

## 9. Spot Eviction & 복구 흐름

> **대상**: 인프라 엔지니어, SRE
>
> Spot VM 퇴거 발생 시 Karpenter(NAP)의 자동 복구 시퀀스를 보여줍니다.
> 핵심 포인트: On-Demand 폴백 미사용 — Spot 용량 부족 Zone에서 다른 Zone으로만 폴백하며,
> PodDisruptionBudget과 TopologySpreadConstraints로 동시 퇴거 영향을 최소화합니다.
> 3개 Zone 모두 Spot 용량 없으면 워크로드 Pending 유지 (의식적 트레이드오프).

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
    KARP->>KARP: NodePool CRD 조건 확인<br/>(sku-family: D, capacity: spot 전용)
    KARP->>AZ: Spot VM 프로비저닝 요청 (Zone 순환)
    alt 현재 Zone Spot 용량 있음
        AZ-->>KARP: 새 Spot VM 생성
    else 현재 Zone Spot 용량 없음
        KARP->>AZ: 다른 Zone Spot VM 프로비저닝 요청
        alt 다른 Zone 용량 있음
            AZ-->>KARP: 다른 Zone Spot VM 생성
        else 전 Zone 용량 없음
            Note over KARP,POD: Pod Pending 유지 — On-Demand 미사용 (정책)
        end
    end
    KARP->>SCHED: 새 노드 Ready
    SCHED->>POD: Pod 재스케줄링
    POD->>POD: 정상 기동

    Note over POD: PDB로 동시 퇴거 제한<br/>TopologySpread로 Zone 분산
```

---

## 10. 백업 & DR 흐름

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

## 11. 설치 워크플로우

> **대상**: 인프라 엔지니어
>
> Phase 1(`tofu apply`, 20~30분)과 Phase 2(`addons/install.sh`, 10~15분)의
> 2단계 설치 과정과 리소스 간 의존 관계를 보여줍니다.
> 핵심 포인트: Phase 1에서 인프라와 AKS 클러스터를 생성하면
> Managed Cilium/Prometheus/Karpenter 등이 자동 활성화되고,
> Phase 2에서 Istio/Flux/Kyverno 등 애드온을 순차 설치합니다.

```mermaid
graph TB
    subgraph Phase1["Phase 1: tofu apply (20~30분)"]
        direction TB
        P1_1["Resource Groups"] --> P1_2["VNet + Subnets + NSG"]
        P1_2 --> P1_3["DNS Zone"]
        P1_2 --> P1_4["Key Vault"]
        P1_2 --> P1_5["Monitor Workspace"]
        P1_2 --> P1_6["Log Analytics"]
        P1_2 --> P1_7["Backup Vault"]
        P1_2 --> P1_ACR["ACR (Basic)"]
        P1_2 --> P1_BAST["Azure Bastion + Jump VM"]
        P1_3 --> P1_8["AKS Clusters (x3)<br/>Private Cluster"]
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
        P2_1 --> P2_9["ESO + Reloader"]
        P2_1 --> P2_10["Defender"]
        P2_1 --> P2_11["AKS Backup"]
    end

    Phase1 --> Phase2

    style Phase1 fill:#e3f2fd,stroke:#1565c0
    style Phase2 fill:#e8f5e9,stroke:#2e7d32
    style P1_AUTO fill:#fff9c4,stroke:#f9a825
```

---

## 12. Korea Central Availability Zone 아키텍처

> **대상**: 인프라 엔지니어, 아키텍트
>
> Korea Central(서울) Zone 1/2/3에 걸친 노드풀 분산 배치와
> Zone 장애 시 서비스 지속 구조를 보여줍니다.
> 핵심 포인트: System + Ingress 노드를 Regular VM으로 3 Zone 분산하여
> 단일 Zone 장애 시에도 Control Plane, Ingress Gateway, 앱 워크로드가 지속됩니다.

```mermaid
graph TB
    subgraph KC["Korea Central (서울)"]

        subgraph Z1["Availability Zone 1"]
            direction TB
            subgraph M1["mgmt"]
                MS1["system (Regular)"]
                MI1["ingress (Regular)"]
                MW1["worker (Spot)"]
            end
            subgraph A1Z1["app1"]
                A1S1["system (Regular)"]
                A1I1["ingress (Regular)"]
                A1W1["worker (Spot)"]
            end
            subgraph A2Z1["app2"]
                A2S1["system (Regular)"]
                A2W1["worker (Spot)"]
            end
        end

        subgraph Z2["Availability Zone 2"]
            direction TB
            subgraph M2["mgmt"]
                MS2["system (Regular)"]
                MI2["ingress (Regular)"]
                MW2["worker (Spot)"]
            end
            subgraph A1Z2["app1"]
                A1S2["system (Regular)"]
                A1I2["ingress (Regular)"]
                A1W2["worker (Spot)"]
            end
            subgraph A2Z2["app2"]
                A2S2["system (Regular)"]
                A2W2["worker (Spot)"]
            end
        end

        subgraph Z3["Availability Zone 3"]
            direction TB
            subgraph M3["mgmt"]
                MS3["system (Regular)"]
                MI3["ingress (Regular)"]
                MW3["worker (Spot)"]
            end
            subgraph A1Z3["app1"]
                A1S3["system (Regular)"]
                A1I3["ingress (Regular)"]
                A1W3["worker (Spot)"]
            end
            subgraph A2Z3["app2"]
                A2S3["system (Regular)"]
                A2W3["worker (Spot)"]
            end
        end
    end

    ALB_M["Azure LB mgmt<br/>(Zone-redundant)"]
    ALB_A1["Azure LB app1<br/>(Zone-redundant)"]

    MI1 & MI2 & MI3 --> ALB_M
    A1I1 & A1I2 & A1I3 --> ALB_A1
    %% app2: Ingress/Istio 미배포 — 외부 LB 없음

    User["User / Browser"]
    User --> ALB_M & ALB_A1

    style Z1 fill:#e3f2fd,stroke:#1565c0
    style Z2 fill:#e8f5e9,stroke:#2e7d32
    style Z3 fill:#fff3e0,stroke:#e65100
```

### Zone 장애 시나리오

```mermaid
sequenceDiagram
    participant AZ as Azure Platform
    participant Z1 as Zone 1 노드
    participant KARP as Karpenter (NAP)
    participant Z23 as Zone 2/3 노드
    participant LB as Azure LB (Zone-redundant)

    AZ->>Z1: Zone 1 장애
    Z1-->>Z1: 노드 Unreachable
    Note over LB: LB는 Zone 2/3 ingress로<br/>자동 트래픽 전환 (무중단)
    Note over KARP: Pending Pod 감지
    KARP->>AZ: Zone 2 또는 3에 Spot VM 요청
    AZ-->>Z23: 새 노드 프로비저닝 (~5분)
    Z23-->>KARP: 노드 Ready
    KARP->>Z23: Worker Pod 재스케줄링
    Note over Z23: Zone 2/3으로 전체 서비스 복구
```

### Korea Central AZ 서비스 지원 현황

```mermaid
graph LR
    subgraph Auto["자동 Zone-redundant"]
        KV["Azure Key Vault"]
        LB2["Azure LB Standard"]
        ACR2["ACR (전 SKU)"]
        MON["Azure Monitor"]
        LAW["Log Analytics"]
    end

    subgraph Manual["수동 설정 필요"]
        AKS["AKS<br/>zones=[1,2,3]"]
        DISK["Managed Disk<br/>Premium_ZRS"]
        BV["Backup Vault<br/>ZoneRedundant"]
    end

    subgraph NotSupported["ZRS 미지원"]
        ULTRA["Ultra Disk"]
        PSSV2["Premium SSD v2"]
    end

    style Auto fill:#e8f5e9,stroke:#2e7d32
    style Manual fill:#e3f2fd,stroke:#1565c0
    style NotSupported fill:#ffebee,stroke:#c62828
```

---

## 13. 관리자 접근 흐름 (Bastion)

> **대상**: 인프라 엔지니어, 보안 엔지니어
>
> 관리자가 AKS 클러스터에 kubectl로 접근하는 유일한 경로를 보여줍니다.
> 핵심 포인트: Jump VM에 Public IP가 없고 Azure Bastion만이 외부 진입점입니다.
> AKS Private Cluster로 공개 엔드포인트가 없어 외부에서 직접 kubectl 실행이 불가합니다.

```mermaid
sequenceDiagram
    actor Admin as 관리자
    participant BPUB as Azure Bastion<br/>(Public IP)
    participant BJMP as Jump VM<br/>(vm-jumpbox, private)
    participant AAD as Entra ID
    participant AKS as AKS API Server<br/>(Private Cluster — VNet 내부 DNS)

    Note over Admin,AKS: 관리자 접근 — Bastion 경유 필수
    Admin->>BPUB: HTTPS :443 (Azure Portal → Bastion Connect)
    BPUB->>AAD: Entra ID 인증
    AAD-->>Admin: MFA 완료
    BPUB->>BJMP: SSH (브라우저 터미널, VNet 내부)
    Note over BJMP: Jump VM 내부에서 작업
    BJMP->>AAD: az login (Managed Identity 또는 CLI)
    AAD-->>BJMP: Access Token
    BJMP->>AKS: az aks get-credentials
    AKS-->>BJMP: kubeconfig 취득
    BJMP->>AKS: kubectl 명령 (VNet 내부 통신)
    AKS-->>BJMP: 응답
    Note over Admin,AKS: Jump VM 외부에서 직접 kubectl 시도 시 — 차단 (Private Cluster, 외부 접근 불가)
```

### 접근 경로 비교

```mermaid
graph LR
    subgraph Blocked["❌ 차단 경로"]
        EXT["외부 PC"] -->|"kubectl (직접)"| AKSAPI["AKS API Server<br/>(Private Cluster — 공개 엔드포인트 없음)"]
    end

    subgraph Allowed["✅ 허용 경로"]
        ADMIN["관리자"] -->|"HTTPS"| BAST["Azure Bastion<br/>(Public IP)"]
        BAST -->|"SSH (private)"| JUMP["Jump VM<br/>(private IP)"]
        JUMP -->|"kubectl<br/>(VNet 내부)"| AKSAPI2["AKS API Server<br/>(Private Cluster)"]
    end

    style Blocked fill:#ffebee,stroke:#c62828
    style Allowed fill:#e8f5e9,stroke:#2e7d32
```
