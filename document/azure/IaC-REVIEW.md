# IaC 구현 검토 및 개선 계획

> **버전**: 1.1.0
> **작성일**: 2026-02-27
> **최종 갱신**: 2026-03-01 (코드 반영 상태 동기화)
> **대상**: 현재 구현된 OpenTofu IaC 코드 (main.tf ~ modules/aks/)
> **목적**: 구현 후 검토 Q&A 결과를 반영한 개선 방향 문서화

---

## 목차

1. [구현 현황 요약](#1-구현-현황-요약)
2. [검토 Q&A 종합 분석](#2-검토-qa-종합-분석)
   - 2.1 [Private IP 고정](#21-private-ip-고정)
   - 2.2 [일괄 리소스 삭제 (tofu destroy)](#22-일괄-리소스-삭제-tofu-destroy)
   - 2.3 [Terraform State → Azure Blob Storage](#23-terraform-state--azure-blob-storage)
3. [개선 항목 목록](#3-개선-항목-목록)
4. [개선 우선순위](#4-개선-우선순위)

---

## 1. 구현 현황 요약

### 생성된 파일 구조

```
azure-k8s-terraform/
├── main.tf                       # Provider 설정 + 모든 모듈 호출
├── variables.tf                  # 전역 유니크 변수 (acr_name, kv_suffix 등)
├── locals.tf                     # location, zones, clusters, vnets, naming
├── outputs.tf                    # RG 이름, 클러스터 ID, kubeconfig 커맨드
├── federation.tf                 # Workload Identity Federated Credentials
├── modules/
│   ├── network/                  # VNet, Subnet, NSG, VNet Peering (풀메시)
│   ├── identity/                 # User-Assigned MI + Role Assignment
│   ├── keyvault/                 # Key Vault (Standard, RBAC mode, Private Endpoint)
│   ├── acr/                      # Container Registry (Basic SKU)
│   ├── monitoring/               # Log Analytics + Monitor Workspace + App Insights
│   ├── backup/                   # Backup Vault (ZoneRedundant) + Policy
│   └── aks/                      # AKS 클러스터, Node Pool, Bastion, Jump VM
└── addons/
    ├── install.sh                 # Phase 2 진입점 (--cluster, --dry-run)
    └── scripts/
        ├── 00-priority-classes.sh
        ├── 00b-gateway-api.sh
        ├── 01-cert-manager.sh
        ├── 02-external-secrets.sh
        ├── 03-reloader.sh
        ├── 04-istio.sh
        ├── 05-kyverno.sh
        ├── 06-flux.sh
        ├── 07-kiali.sh
        ├── 08-karpenter-nodepool.sh
        ├── 09-backup-extension.sh
        ├── 10-defender.sh
        ├── 11-budget-alert.sh
        ├── 12-aks-automation.sh
        ├── 13-hubble.sh
        └── 14-verify-clusters.sh
```

### 생성 리소스 예상 수

| 모듈 | 주요 리소스 | 예상 수 |
|------|------------|--------|
| network | RG, VNet×3, Subnet×5, NSG×5, Peering×6 | ~20 |
| identity | MI×9, RoleAssignment×9+ | ~20 |
| keyvault | Key Vault×1, RoleAssignment×1, Private Endpoint×1, Private DNS Zone×1 | 5+ |
| acr | ACR×1 | 1 |
| monitoring | LAW×1, MonitorWorkspace×1, AppInsights×1 | 3 |
| backup | BackupVault×1, BackupPolicy×1 | 2 |
| aks | RG×3, AKS×3, NodePool×6(system×3+ingress×2), Bastion×1, JumpVM×1, NIC×1, PIP×1 | ~18 |
| federation | FederatedCredential×3 (cert-manager) | 3 |
| **합계** | | **~72 리소스** |

> NodePool은 system×3 + ingress×2(mgmt,app1) = 5. Worker Pool은 NAP/Karpenter가 관리하므로 Terraform에서 생성하지 않음.

---

## 2. 검토 Q&A 종합 분석

---

### 2.1 Private IP 고정

#### 질문
> "terraform 코드 기반으로 인프라 구축 시 네트워크 Private IP 고정이 되는지?"

#### 양측 답변 종합

| 관점 | 내용 |
|------|------|
| **고정되는 것** (현재 코드) | VNet/Subnet CIDR (10.1.0.0/16 등) — locals.tf에 하드코딩 |
| **고정되는 것** (현재 코드) | Jump VM NIC — Static 할당, 10.1.1.10 고정 |
| **고정되지 않는 것** (현재 코드) | AKS 노드 IP (동적) |
| **Azure 플랫폼 가능 범위** | NIC `Static` 할당, Internal LB, Application Gateway는 IP 고정 가능 |
| **AKS 서비스 레벨** | `service.beta.kubernetes.io/azure-load-balancer-ipv4` Annotation으로 Internal LB IP 고정 가능 |

#### 현재 코드 상태 — 구현 완료

> **v1.1.0 갱신**: H1, H2 개선 항목이 코드에 반영 완료됨.

```hcl
# modules/aks/main.tf:262-267 — Static IP 적용 완료
ip_configuration {
  name                          = "ipconfig-jumpbox"
  subnet_id                     = var.jumpbox_subnet_id
  private_ip_address_allocation = "Static"
  private_ip_address            = var.jumpbox_private_ip  # 10.1.1.10
}
```

```hcl
# modules/aks/variables.tf:118-127 — 변수 + validation 추가 완료
variable "jumpbox_private_ip" {
  description = "Static private IP for Jump VM (must be within jumpbox subnet 10.1.1.0/24)"
  type        = string
  default     = "10.1.1.10"

  validation {
    condition     = can(cidrhost("10.1.1.0/24", 0)) && can(regex("^10\\.1\\.1\\.", var.jumpbox_private_ip))
    error_message = "jumpbox_private_ip must be within 10.1.1.0/24 (e.g. 10.1.1.10)."
  }
}
```

```hcl
# locals.tf:68 — 고정 IP 중앙 관리
jumpbox_private_ip = "10.1.1.10"
```

#### 향후 개선 여지

| 대상 | 방법 | 우선순위 |
|------|------|---------|
| ~~Jump VM NIC~~ | ~~`Static` + 명시적 IP~~ | ~~**High**~~ **완료** |
| Internal LB (향후) | Kubernetes Service Annotation으로 고정 | Medium — Addon 단계 |
| AKS 노드 IP | 일반적으로 고정 불필요 (Pod는 Overlay) | Low |

---

### 2.2 일괄 리소스 삭제 (tofu destroy)

#### 질문
> "해당 코드로 삭제 진행시 일괄적인 리소스 삭제가 가능한지?"

#### 양측 답변 종합

| 관점 | 내용 |
|------|------|
| **원칙** | `tofu destroy`는 state 기반 역순 삭제 → 의존성 자동 처리 |
| **가능한 것** | state에 등록된 모든 ~72개 리소스 |
| **예외/주의** | Key Vault soft-delete, Backup Vault soft-delete, AKS 동적 생성 리소스 |

#### 삭제 시 예상 문제점 상세

**① Key Vault Soft Delete**

```hcl
# modules/keyvault/main.tf:19-20
soft_delete_retention_days = 90     # 90일 보존 (Azure 강제)
purge_protection_enabled   = false  # Demo: purge 허용
```

- `tofu destroy` 후 KV는 "삭제됨(soft-deleted)" 상태로 90일 보존
- **동일 이름으로 재생성 불가** (이름 충돌) → `tofu apply` 재실행 시 오류 발생 가능
- 해결: `az keyvault purge --name <kv-name>` 또는 `kv_suffix` 변경 후 재생성

**② Backup Vault Soft Delete — 구현 완료**

> **v1.1.0 갱신**: H3, H4 개선 항목이 코드에 반영 완료됨.

```hcl
# modules/backup/main.tf:17 — 변수 기반 조건 처리 적용 완료
soft_delete = var.enable_soft_delete ? "On" : "Off"
```

```hcl
# modules/backup/variables.tf:19-23 — 변수 추가 완료
variable "enable_soft_delete" {
  description = "Enable soft delete on Backup Vault. false = 즉시 삭제 (demo/dev), true = 보존 (prod)"
  type        = bool
  default     = false
}
```

```hcl
# main.tf:147 — 루트 모듈에서 Demo 환경 false 전달
enable_soft_delete = false  # Demo: 즉시 삭제 허용 (prod 전환 시 true)
```

- Demo 환경(`false`): `tofu destroy` 시 Backup Vault 즉시 삭제 가능
- Prod 환경(`true`): BackupInstance 먼저 삭제 → Vault 삭제 순서 필요
- BackupInstance는 Addon 단계(스크립트)에서 생성되므로 **state 밖에 존재**할 수 있음에 주의

**③ AKS 동적 생성 리소스 (State 外)**

AKS가 자동으로 생성하는 리소스는 Terraform state에 없음:

| 리소스 | 생성 주체 | 삭제 방법 |
|--------|---------|---------|
| Private DNS Zone (`privatelink.*.azmk8s.io`) | AKS 자동 생성 | AKS 삭제 시 연동 삭제 |
| Node RG (`MC_*`) | AKS 자동 생성 | AKS 삭제 시 연동 삭제 |
| Azure Load Balancer (Ingress용) | AKS/K8s | Service 삭제 후 AKS 삭제 |
| PersistentVolume (Azure Disk) | AKS/K8s | `kubectl delete pv` 후 AKS 삭제 |
| Karpenter/NAP 프로비저닝 노드 | Karpenter | 자동 회수 (드레인 후) |

#### 개선 방향

| 항목 | 개선 내용 | 우선순위 |
|------|---------|---------|
| Key Vault 재사용성 | destroy 스크립트에 purge 단계 추가 | Medium |
| ~~Backup Vault~~ | ~~`enable_soft_delete` 변수화~~ | ~~**High**~~ **완료** |
| 삭제 가이드 | `DESTROY.md` 작성 (순서/주의사항) | Medium |
| `tofu destroy` 전처리 | Pre-destroy script (K8s 리소스 정리) | Medium |

---

### 2.3 Terraform State → Azure Blob Storage

#### 질문
> "terraform state 코드는 Blob Storage에 저장이 가능한지? (확인만)"

#### 양측 답변 종합

| 관점 | 내용 |
|------|------|
| **가능 여부** | 가능 (OpenTofu azurerm backend 완전 지원) |
| **현재 상태** | `backend "local"` — 로컬 파일 |
| **마이그레이션** | `tofu init -migrate-state` 한 번으로 이전 |
| **엔터프라이즈 표준** | State Locking (Blob Lease)으로 동시 작업 무결성 보장 |

#### 현재 main.tf 상태

```hcl
# main.tf:23-39 — 주석으로 이미 작성됨
backend "local" {}    # 현재: 로컬 파일

# 향후 azurerm backend로 교체:
# backend "azurerm" {
#   resource_group_name  = "rg-tfstate"
#   storage_account_name = "<globally-unique-name>"
#   container_name       = "tfstate"
#   key                  = "azure-k8s-demo/main.tfstate"
#   use_azuread_auth     = true   # MSI/OIDC — credentials 불필요
# }
```

#### 마이그레이션 전체 절차

```bash
# Step 1: tfstate용 Storage Account 생성 (IaC 외부 — 부트스트랩)
az group create --name rg-tfstate --location koreacentral
az storage account create \
  --name tfstate<unique-suffix> \
  --resource-group rg-tfstate \
  --sku Standard_LRS \
  --allow-blob-public-access false

az storage container create \
  --name tfstate \
  --account-name tfstate<unique-suffix>

# Step 2: main.tf backend 블록 교체 (local → azurerm)
# (주석 해제)

# Step 3: 마이그레이션 (자동 이전)
tofu init -migrate-state
# → "Do you want to copy existing state to the new backend? [yes]" 에 yes

# Step 4: 로컬 state 파일 삭제 (선택)
rm terraform.tfstate terraform.tfstate.backup
```

#### 추가 고려사항

| 항목 | 내용 |
|------|------|
| **State Locking** | Blob Lease 기반 자동 잠금 — 동시 `apply` 방지 |
| **암호화** | Azure Storage 기본 암호화 (AES-256) + 선택적 CMK |
| **접근 제어** | Storage Account에 RBAC (Storage Blob Data Contributor) 설정 권장 |
| **버전 관리** | Storage Account versioning 활성화 → state 이력 보존 |
| **백업** | tfstate 파일 자체 삭제 방지를 위해 Blob Soft Delete 활성화 권장 |

#### 개선 코드 (backend 모듈화)

```hcl
# backend.tf (별도 파일로 분리 — 환경별 관리 용이)
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "tfstateak8sdemo"   # 실제 고유 이름으로 변경
    container_name       = "tfstate"
    key                  = "azure-k8s-demo/prod.tfstate"
    use_azuread_auth     = true                # MSI/OIDC 인증 (credentials 불필요)
  }
}
```

---

## 3. 개선 항목 목록

검토 결과를 기반으로 코드 수정이 필요한 항목을 정리합니다.

### 3.1 즉시 수정 필요 (High) — 모두 완료

| # | 파일 | 상태 | 내용 |
|---|------|------|------|
| ~~H1~~ | `modules/aks/main.tf` | **완료** | Jump VM NIC: `Static` + `10.1.1.10` 고정 |
| ~~H2~~ | `modules/aks/variables.tf` | **완료** | `jumpbox_private_ip` 변수 + validation 추가 |
| ~~H3~~ | `modules/backup/main.tf` | **완료** | `soft_delete` 변수화 (`enable_soft_delete`) |
| ~~H4~~ | `modules/backup/variables.tf` | **완료** | `enable_soft_delete` 변수 추가 (`default = false`) |

### 3.2 중기 개선 (Medium)

| # | 파일 | 현재 상태 | 개선 내용 |
|---|------|---------|---------|
| M1 | `main.tf` | `backend "local"` | `backend "azurerm"` 전환 (별도 `backend.tf`) |
| M2 | 신규 | 없음 | `DESTROY.md` — 삭제 순서/주의사항 가이드 |
| M3 | 신규 | 없음 | `scripts/pre-destroy.sh` — K8s 리소스 사전 정리 |
| M4 | `modules/keyvault/main.tf` | purge_protection=false 주석만 | 변수화 + destroy 후 purge 가이드 주석 보강 |

### 3.3 장기 개선 (Low)

| # | 파일 | 현재 상태 | 개선 내용 |
|---|------|---------|---------|
| L1 | `modules/aks/main.tf` | Internal LB IP 미설정 | Addon 단계에서 Service Annotation으로 처리 |
| L2 | `modules/backup/` | BackupInstance state 외부 | Terraform 리소스로 편입 검토 |
| L3 | `main.tf` | budget/automation 모듈 없음 | `modules/budget/` 신규 모듈로 IaC화 |

---

## 4. 개선 우선순위

```
Phase 1 (즉시): H1 ~ H4 코드 수정 — ✅ 모두 완료
  ✅ Jump VM IP 고정 (Static + 10.1.1.10)
  ✅ Backup Vault soft_delete 변수화 (enable_soft_delete)

Phase 2 (중기): M1 ~ M4
  └─ Backend → Azure Blob Storage 전환
  └─ DESTROY.md 가이드 작성
  └─ pre-destroy.sh 스크립트

Phase 3 (장기): L1 ~ L3
  └─ Budget 모듈 IaC화
  └─ BackupInstance state 편입
```

### 검증 단계 (Phase 1 완료 후)

```bash
# 문법 검증
tofu init
tofu validate

# 계획 확인 (~72 리소스, 오류 없음 목표)
tofu plan -out=tfplan

# 예상 출력:
# Plan: 72 to add, 0 to change, 0 to destroy.
```

---

*이 문서는 구현 검토 결과를 반영하며, v1.1.0에서 H1~H4 코드 반영 완료 상태를 동기화했습니다.*
