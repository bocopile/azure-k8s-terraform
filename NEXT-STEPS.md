# 다음 작업 목록 (2026-03-08 업데이트)

## 완료된 작업

### 배포 관련
- [x] DSv4 쿼터 20 → 32 증가 (`az quota update`)
- [x] Total Regional vCPU 20 → 50 증가
- [x] ingress 노드풀 Spot → Regular 전환 (LowPriorityCores 쿼터 부족 대응)
- [x] AKS Diagnostic Setting 3개 `tofu import` 등록
- [x] 배포 완료 (118개 리소스, k8s v1.35.0)
- [x] 배포 후 모니터링 체크리스트 완료 — 전체 이상 없음
- [x] 전체 리소스 삭제 (`tofu destroy`) — 재배포 대기 중

### 코드 / 문서
- [x] `pre-destroy.sh` — `az aks command invoke` 방식 전환 (VPN 불필요)
- [x] `DESTROY.md` — 수동 정리 명령어 업데이트
- [x] `README.md` — 배포 후 모니터링 + 크리티컬 장애 대응 섹션 추가
- [x] `check-resources.sh` — `${KV_SUFFIX,,}` → `tr` 변환 (macOS 호환)

### P1–P4
- [x] P1. Remote Backend — Azure Blob Storage (`backend.tf`)
- [x] P2. Jump VM User-Assigned MI + RBAC + cloud-init 통합 (az CLI + kubectl + addon 설치)
- [x] P3. Network Watcher 네이밍 개선 (`nw-koreacentral` → `nw-k8s`)
- [x] P4. AKS 노드 OS → Azure Linux (`os_sku = "AzureLinux"`)

### Critical (C1–C7) — 코드 구현 완료
- [x] C1. DCE `public_network_access_enabled = true` (`prometheus.tf`)
- [x] C2. Grafana `grafana_public_access = true` (기본값)
- [x] C3. mTLS — `04b-istio-mtls.sh` (PeerAuthentication STRICT + DestinationRule)
- [x] C4. cert-manager ClusterIssuer — `01-cert-manager.sh` (HTTP-01 / DNS-01)
- [x] C5. Kiali CR — `07-kiali.sh` (Operator + CR 생성)
- [x] C6. Flux FluxConfig — `06-flux.sh` (Extension + FluxConfig + SSH Key)
- [x] C7. AKS Backup Instance — `modules/backup/main.tf` (`azurerm_data_protection_backup_instance_kubernetes_cluster`)

### Moderate (M1–M4)
- [x] M1. Karpenter NodePool — `["spot"]` 전용 (`08-karpenter-nodepool.sh`)
- [x] M2. ACR Premium — 운영 전환 시 고려사항 문서화 (NEXT-STEPS.md)
- [x] M3. Sentinel MCAS 분리 — `enable_mcas` 변수 추가 (`variables.tf`, `monitoring/main.tf`)
- [x] M4. Network Watcher 보호 — `lifecycle { prevent_destroy = true }` (`flow-logs.tf`)

### Minor (m1–m4) — 코드 확인 후 완료
- [x] m1. Gateway API 버전 주석 불일치 수정 (`00b-gateway-api.sh`)
- [x] m2. Kiali 버전 주석 불일치 수정 (`07-kiali.sh`)
- [x] m4. ACR Diagnostic Settings — `modules/acr/main.tf`에 이미 구현됨

### P5. Data Services 모듈
- [x] `modules/data-services/` 생성 — Redis / MySQL / Service Bus
- [x] Private Endpoint + Private DNS Zone (mgmt/app1/app2 VNet 링크)
- [x] Connection String → Key Vault Secret 자동 저장
- [x] Enable 플래그 기반 선택적 배포 (`enable_redis`, `enable_mysql`, `enable_servicebus`)

### Key Vault
- [x] `kv_suffix` 변경: `2cfd` → `9340` (soft-delete 충돌 방지)
- [x] `purge_soft_delete_on_destroy = true` (재배포 시 자동 purge)
- [x] `keyvault_purge_protection` 기본값 `true` → `false`

---

## 미결 작업

### 🔴 재배포 필요
- [ ] `tofu apply` 실행 — 인프라 전체 재구성 (현재 리소스 0개)
- [ ] Addon 스크립트 순서대로 실행: **`13-hubble.sh` 먼저** → `00-priority-classes.sh` → ... → `14-verify-clusters.sh`
  - `13-hubble.sh`를 맨 먼저 실행해야 함 (ACNS Cilium 재시작 안정화 필수)

### 🟡 검증 필요 (클러스터 기동 후)
- [ ] m3. Tetragon + Managed Cilium 충돌 여부 실제 검증 (`TETRAGON_FORCE=true ./15-tetragon.sh`)
- [ ] C3. mTLS STRICT 실제 동작 확인 (`kubectl get peerauthentication -A`)
- [ ] C7. Backup Instance 연결 상태 확인 (`az dataprotection backup-instance list`)

### 🟢 운영 전환 시
- [ ] M2. ACR Basic → Premium + Private Endpoint — **해당 없음 (현재 환경 유지 결정)**

---

## v2.0 다음 버전 작업 계획

### 🔴 Critical — 재배포 시 필수 해결

#### 1. Cilium CNI 안정화 (2026-03-08 실환경 장애에서 도출)
- **문제**: `az aks update --enable-acns` 실행 후 Cilium DaemonSet 재시작 중에 다른 addon Pod들이 IP를 못 받아 ContainerCreating/Pending stuck 발생
- **해결(완료)**: `13-hubble.sh` — Cilium rollout status 대기 + CNS 안정화 30s 대기 추가
- **해결(완료)**: `install.sh` — Step 13 (Hubble)을 가장 먼저 실행하도록 순서 변경
- [ ] **검증 필요**: 다음 배포에서 ContainerCreating stuck 재발 여부 확인

#### 2. Kyverno containerd zombie 복구 (2026-03-08 실환경 장애)
- **문제**: `failed to reserve container name` — CNI 장애로 불완전 종료된 containerd 컨테이너가 재시작 시 충돌
- **해결(완료)**: `05-kyverno.sh` — 재설치 전 Terminating/CreateContainerError Pod 강제 제거
- **해결(완료)**: `05-kyverno.sh` — 이미지 레지스트리 `reg.kyverno.io` → `ghcr.io` (pull 속도 30분+ → 정상)
- [ ] **검증 필요**: Kyverno v1.17.1이 Helm chart v3.7.1과 실제로 배포되는지 확인

#### 3. Istio istiod Ready 대기
- **문제**: `az aks mesh enable` 완료 후 istiod Pod가 아직 준비 안 된 상태에서 `04b-istio-mtls.sh` 실행 시 webhook 오류 가능
- **해결(완료)**: `04-istio.sh` — istiod deployment rollout status 대기 추가

### 🟡 중요 — v2.0 신규 개선 항목

#### 4. Data Services 배포 (document/azure/DATA-SERVICES.md)
- [ ] Redis Premium P1 (6GB, Zone Redundant) 배포 — `enable_redis = true`
- [ ] MySQL Burstable B2ms 배포 — `enable_mysql = true`
- [ ] Service Bus Premium 1CU 배포 — `enable_servicebus = true`
- **예상 추가 비용**: +$920/월 (Service Bus Premium이 $667로 최대)
- **사전 작업**: Private Endpoint + DNS Zone 설계 확인

#### 5. DCE Private Endpoint 추가 (MEMORY.md §인프라 미결 이슈)
- [ ] `prometheus.tf:16` — DCE에 Private Endpoint + Private DNS Zone 연결
- [ ] Grafana Private Endpoint + VNet 통합 (현재 공개 접근 차단 + PE 없어서 대시보드 접근 불가)
- **선행 조건**: `enable_grafana = true` + Private DNS Zone 설계

#### 6. Flux GitOps 실제 연결
- [ ] GitOps 전용 레포(`GITOPS_REPO_URL`) 준비 및 Flux bootstrap 완료
- [ ] `GITOPS_REPO_URL` 설정 후 `06-flux.sh` 재실행
- [ ] Kustomization으로 app1/app2 워크로드 배포 자동화

#### 7. Tetragon AKS 네이티브 지원 확인
- [ ] `az aks show ... --query 'securityProfile'`로 AKS 네이티브 Tetragon 지원 여부 확인
- [ ] 지원 안 될 경우 `TETRAGON_FORCE=true`로 강제 설치 + eBPF 충돌 모니터링
- [ ] TracingPolicy 커스텀 정책 작성 (프로세스 실행, 파일 접근 추적)

### 🟢 Optional — v2.0 고도화

#### 8. ACR 이미지 미러링
- [ ] `reg.kyverno.io`, `docker.io` 등 외부 레지스트리 이미지를 ACR로 미러링
- [ ] AKS ImagePullSecret 또는 NodeClass imageGCHighThresholdPercent 설정
- [ ] Karpenter NodePool에서 ACR 미러 레지스트리 사용

#### 9. Budget Alert 자동화
- [ ] `BUDGET_ALERT_EMAIL` 환경변수 설정 후 `11-budget-alert.sh` 재실행
- [ ] Azure Cost Anomaly Alert 추가 (`az costmanagement alert`)
- [ ] Grafana 대시보드에 비용 패널 추가

#### 10. AKS 버전 업그레이드 경로
- [ ] Kubernetes 1.35 → 1.36 업그레이드 계획 수립 (안정화 후)
- [ ] Istio asm-1-28 → asm-1-29 마이그레이션 검토
- [ ] Karpenter 1.6.5-aks → 최신 버전 업데이트

---

---

## soft-deleted Key Vault 현황
| 이름 | 자동 purge 예정 | 비고 |
|------|----------------|------|
| `kv-k8s-2cfd` | 2026-06-03 | purge_protection=true, 수동 purge 불가 |
| `kv-k8s-abc123` | 2026-06-02 | purge_protection=true, 수동 purge 불가 |

→ 다음 배포는 `kv-k8s-9340`으로 충돌 없음
