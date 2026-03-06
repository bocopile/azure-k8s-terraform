# 운영 환경 전환 가이드 (Production Sizing Guide)

데모/시연 설정(`terraform.tfvars.example`)에서 운영 환경으로 전환 시 검토해야 할 항목을 정리한다.

---

## 1. 노드 구성

| 항목 | 데모 (최소) | 운영 (권장) | 이유 |
|------|------------|------------|------|
| `aks_sku_tier` | `"Free"` | `"Standard"` | Control Plane HA + SLA 99.9% 보장 |
| `system_node_count` | `1` | `3` | AZ 1/2/3 분산 — AZ 장애 시 서비스 유지 |
| `ingress_node_count` | `1` | `3` | AZ 분산 HA |
| `vm_size_system` | `Standard_D2s_v4` | `Standard_D4s_v5` 이상 | 시스템 풀 여유 확보 (addon 증가 대응) |
| `vm_size_ingress` | `Standard_D2s_v4` | `Standard_D4s_v5` 이상 | Istio sidecar + 실 트래픽 처리 |

> **주의**: `vm_size_system/ingress`는 데모에서도 `Standard_D2s_v4`(2vCPU/8GB) 이하로
> 낮추면 Istio + cert-manager + ESO addon 설치 중 OOM/스케줄 실패가 발생할 수 있다.

---

## 2. 보안

| 항목 | 데모 | 운영 | 비고 |
|------|------|------|------|
| `keyvault_purge_protection` | `false` | `true` | 실수로 인한 KV 삭제 영구 방지 |
| `backup_soft_delete` | `false` | `true` | Backup Vault 삭제 후 14일 보존 |
| `grafana_public_access` | `true` | `false` | Private Endpoint 추가 필요 |
| `acr_sku` | `"Basic"` | `"Standard"` 또는 `"Premium"` | Private Endpoint 사용 시 Basic 불가 |
| `acr_enable_private_endpoint` | `false` | `true` | Standard/Premium SKU 필수 |
| `kv_allowed_ips` | 로컬 IP | 파이프라인 에이전트 IP | CI/CD 실행 환경 IP 추가 |

---

## 3. 관측성

| 항목 | 데모 | 운영 | 비고 |
|------|------|------|------|
| `enable_grafana` | `false` | `true` | |
| `grafana_sku` | — | `"Standard"` | Essential은 대시보드/알림 기능 제한 |
| `log_retention_days` | `30` | `90` 이상 | 규정 준수 요건 확인 (금융: 5년 등) |
| `flow_log_retention_days` | `30` | `90` 이상 | |
| `backup_retention_duration` | `"P7D"` | `"P30D"` 이상 | |
| `enable_sentinel` | `false` | `true` | 보안 이벤트 수집/분석 필요 시 |

---

## 4. 네트워크 — NAT Gateway

현재 `outbound_type = "loadBalancer"` (SNAT 방식)로 고정되어 있다.
대규모 트래픽 처리 시 SNAT 포트 고갈(Port Exhaustion) 위험이 있다.

**증상**: 간헐적 connection timeout, 외부 API 호출 실패
**임계치**: 노드당 약 1,024개 SNAT 포트 (기본 할당)

운영 전환 시 클러스터당 NAT Gateway 1개 도입을 검토한다.

```hcl
# modules/aks/main.tf — 향후 추가 예정
network_profile {
  outbound_type = "userAssignedNATGateway"
  # NAT Gateway: 약 $32/월/클러스터 × 3 = ~$96/월 추가
}
```

---

## 5. 데이터 서비스 (enable_redis / enable_mysql / enable_servicebus)

기본값은 모두 `false`. 운영 전환 시 아래 항목을 별도로 조정한다.

### Redis

| 항목 | 데모 기본 | 운영 권장 |
|------|---------|---------|
| `redis_capacity` | `1` (6GB) | 워크로드에 맞게 조정 (2=13GB, 3=26GB) |
| AOF 지속성 | `false` (코드 고정) | 운영 시 `aof_backup_enabled = true` 변수화 검토 |

### MySQL

| 항목 | 데모 기본 | 운영 권장 |
|------|---------|---------|
| `mysql_sku_name` | `B_Standard_B2ms` | `GP_Standard_D4ds_v4` 이상 |
| geo-redundancy | `false` (코드 고정) | `geo_redundant_backup_enabled = true` 변수화 검토 |
| `mysql_storage_gb` | `20` | 예상 데이터 크기 × 1.5 여유율 |

### Service Bus

| 항목 | 데모 기본 | 운영 권장 |
|------|---------|---------|
| `servicebus_capacity` | `1` | 메시지 처리량에 맞게 조정 (1/2/4/8) |

---

## 6. Jump VM 이미지 버전 고정

운영 환경에서는 `jumpbox_image_version = "latest"` 대신 특정 버전으로 고정한다.
재배포 시 예기치 않은 이미지 변경을 방지한다.

```bash
# 사용 가능한 버전 조회
az vm image list \
  --publisher Canonical \
  --offer ubuntu-24_04-lts \
  --sku server \
  --all \
  --output table | tail -10
```

```hcl
# terraform.tfvars
jumpbox_image_version = "24.04.202501140"  # 확인된 버전으로 고정
```

---

## 7. 비용 예측 참고

| 구성 | 예상 월 비용 |
|------|------------|
| 데모 (Free tier, 1노드/클러스터) | ~$400–600 |
| 운영 최소 (Standard tier, 3노드/클러스터, D2s_v4) | ~$1,200–1,500 |
| 운영 권장 (Standard tier, 3노드/클러스터, D4s_v5) | ~$2,000–2,500 |

> 비용은 Korea Central 리전 기준 추정치. Azure Pricing Calculator로 정확한 산출 필요.
> Karpenter Spot 노드풀 활용 시 워커 노드 비용 최대 80% 절감 가능.

---

## 8. 운영 전환 체크리스트

- [ ] `aks_sku_tier = "Standard"` 적용
- [ ] `system_node_count = 3`, `ingress_node_count = 3` 적용
- [ ] VM 크기 재검토 (D2s_v4 → D4s_v5 이상)
- [ ] `keyvault_purge_protection = true`
- [ ] `backup_soft_delete = true`
- [ ] `grafana_public_access = false` + Private Endpoint 구성
- [ ] ACR SKU Standard/Premium 전환 + Private Endpoint 활성화
- [ ] 로그 보존 기간 규정 준수 기준으로 조정
- [ ] `jumpbox_image_version` 특정 버전 고정
- [ ] NAT Gateway 도입 여부 결정
- [ ] CI/CD 파이프라인 IP → `kv_allowed_ips` 추가
- [ ] `enable_sentinel = true` 보안 요건 검토
