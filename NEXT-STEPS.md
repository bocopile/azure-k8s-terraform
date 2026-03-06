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
- [x] P2. Jump VM System-Assigned MI + RBAC + CustomScript Extension
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

## 운영 환경 전환 시 고려사항 (Production Sizing Guide)

> 데모/시연 설정(`terraform.tfvars.example`)과의 차이점을 중심으로 정리.

### 노드 구성

| 항목 | 데모 (최소) | 운영 (권장) | 이유 |
|------|------------|------------|------|
| `aks_sku_tier` | `"Free"` | `"Standard"` | SLA 99.9% 보장, Control Plane HA |
| `system_node_count` | `1` | `3` | AZ 분산 HA (AZ 장애 시 서비스 유지) |
| `ingress_node_count` | `1` | `3` | AZ 분산 HA |
| `vm_size_system` | `Standard_D2s_v4` | `Standard_D4s_v5` 이상 | 워크로드 증가 시 시스템 풀 여유 확보 |
| `vm_size_ingress` | `Standard_D2s_v4` | `Standard_D4s_v5` 이상 | Istio sidecar + 실 트래픽 처리 |

> `vm_size_system/ingress`는 데모에서도 `Standard_D2s_v4` 이하로 낮추면
> Istio + cert-manager + ESO addon 설치 중 OOM/스케줄 실패 발생 가능.

### 보안

| 항목 | 데모 | 운영 |
|------|------|------|
| `keyvault_purge_protection` | `false` | `true` — 실수로 인한 KV 삭제 영구 방지 |
| `backup_soft_delete` | `false` | `true` — Backup Vault 삭제 14일 보존 |
| `grafana_public_access` | `true` | `false` + Private Endpoint 추가 |
| `acr_sku` | `Basic` | `Standard` 또는 `Premium` + Private Endpoint |
| `acr_enable_private_endpoint` | `false` | `true` (Standard/Premium SKU 필수) |

### 관측성 / 비용

| 항목 | 데모 | 운영 |
|------|------|------|
| `enable_grafana` | `false` | `true` |
| `grafana_sku` | — | `"Standard"` (Essential은 기능 제한) |
| `log_retention_days` | `30` | `90` 이상 (규정 준수 요건 확인) |
| `flow_log_retention_days` | `30` | `90` 이상 |
| `backup_retention_duration` | `"P7D"` | `"P30D"` 이상 |
| `enable_sentinel` | `false` | `true` (보안 이벤트 수집/분석 필요 시) |

### 네트워크 (NAT Gateway)

현재 `outbound_type = "loadBalancer"` (SNAT 방식) 유지 중.
대규모 트래픽 처리 시 SNAT 포트 고갈 위험 → 운영 전환 시 NAT Gateway 도입 검토.

```hcl
# 향후 추가 예정 — 클러스터당 NAT Gateway 1개 (약 $32/월)
# outbound_type = "userAssignedNATGateway"
```

### 데이터 서비스

Redis, MySQL, Service Bus는 기본 `false`. 운영 전환 시 활성화 후 아래 항목 재검토:

| 항목 | 데모 기본값 | 운영 권장 |
|------|------------|---------|
| `redis_capacity` | `1` (6GB) | 워크로드에 맞게 조정 |
| MySQL `aof_backup_enabled` | `false` | `true` (재시작 시 데이터 손실 방지) |
| MySQL `geo_redundant_backup_enabled` | `false` | `true` (재해 복구) |
| `mysql_sku_name` | `B_Standard_B2ms` | `GP_Standard_D4ds_v4` 이상 |

### Jump VM 이미지 버전

운영 환경에서는 `jumpbox_image_version = "latest"` 대신 특정 버전 고정 권장.

```bash
# 사용 가능한 버전 조회
az vm image list -p Canonical -f ubuntu-24_04-lts --sku server --all -o table | tail -10
```

```hcl
# terraform.tfvars
jumpbox_image_version = "24.04.202501140"  # 확인된 버전으로 고정
```

---

## soft-deleted Key Vault 현황
| 이름 | 자동 purge 예정 | 비고 |
|------|----------------|------|
| `kv-k8s-2cfd` | 2026-06-03 | purge_protection=true, 수동 purge 불가 |
| `kv-k8s-abc123` | 2026-06-02 | purge_protection=true, 수동 purge 불가 |

→ 다음 배포는 `kv-k8s-9340`으로 충돌 없음
