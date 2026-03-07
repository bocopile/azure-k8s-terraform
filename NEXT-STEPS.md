# 다음 작업 목록 (2026-03-05 업데이트)

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
- [ ] Addon 스크립트 순서대로 실행 (`00-priority-classes.sh` → ... → `17-grafana-dashboards.sh`)

### 🟡 검증 필요 (클러스터 기동 후)
- [ ] m3. Tetragon + Managed Cilium 충돌 여부 실제 검증 (`15-tetragon.sh`)
- [ ] C3. mTLS STRICT 실제 동작 확인 (`kubectl get peerauthentication -A`)
- [ ] C7. Backup Instance 연결 상태 확인 (`az dataprotection backup-instance list`)

### 🟢 운영 전환 시
- [ ] M2. ACR Basic → Premium + Private Endpoint — **해당 없음 (현재 환경 유지 결정)**

---

---

## soft-deleted Key Vault 현황
| 이름 | 자동 purge 예정 | 비고 |
|------|----------------|------|
| `kv-k8s-2cfd` | 2026-06-03 | purge_protection=true, 수동 purge 불가 |
| `kv-k8s-abc123` | 2026-06-02 | purge_protection=true, 수동 purge 불가 |

→ 다음 배포는 `kv-k8s-9340`으로 충돌 없음
