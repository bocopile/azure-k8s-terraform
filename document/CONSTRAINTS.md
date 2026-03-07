# 현재 구성 제약사항 및 운영 한계

이 문서는 현재 데모/시연 환경에서 적용된 비용 절감 설정의 제약사항과,
운영(Prod) 전환 시 변경해야 할 항목을 정리합니다.

---

## 1. AKS SKU Tier: `Free`

### 현재 설정
```hcl
aks_sku_tier = "Free"
```

### 제약사항

| 항목 | Free | Standard |
|------|------|----------|
| Control Plane SLA | ❌ 없음 | ✅ 99.95% |
| Control Plane 가용성 | 베스트 에포트 | 보장 |
| Control Plane 응답시간 | 느릴 수 있음 | 안정적 |
| AKS 업스케일 지원 | ✅ | ✅ |
| 클러스터당 비용 | $0 | ~$72/월 (3클러스터 = +$216/월) |

### 구체적 위험
- API Server가 응답하지 않아도 Azure SLA 보상 없음
- `az aks command invoke` 타임아웃 빈도 증가 가능
- 장애 시 Azure 지원팀 우선순위 낮음
- 대규모 트래픽 급증 시 Control Plane 응답 저하 가능

### 운영 전환 조건
- 서비스 트래픽 수신 시작 → **즉시 Standard 전환 필수**
- `terraform.tfvars`: `aks_sku_tier = "Standard"`

---

## 2. ACR SKU: `Basic`

### 현재 설정
```hcl
acr_sku = "Basic"
```

### 제약사항

| 항목 | Basic | Standard | Premium |
|------|-------|----------|---------|
| 스토리지 | 10 GB | 100 GB | 500 GB |
| 처리량 | 낮음 | 중간 | 높음 |
| Private Endpoint | ❌ | ✅ | ✅ |
| Geo-replication | ❌ | ❌ | ✅ |
| 콘텐츠 신뢰 | ❌ | ❌ | ✅ |
| 월 비용 | ~$5 | ~$20 | ~$50 |

### 구체적 위험
- **이미지가 공개 인터넷 경유**: AKS → ACR pull 시 인터넷을 통함
  - 보안 정책상 문제 (네트워크 트래픽 감사 불가)
  - 이그레스 비용 발생 (대용량 이미지 시 무시 불가)
  - Basic SKU는 Private Endpoint 미지원 → VNet 내부 경유 불가
- **스토리지 한계**: 이미지가 많아지면 10 GB 초과 가능
- **처리량 한계**: 멀티 클러스터 동시 pull 시 rate limit 도달 가능
- ACR Firewall 규칙 미지원 → 특정 VNet에서만 접근 제한 불가

### 운영 전환 조건
- Private Endpoint 필요 시 → **Standard 이상으로 업그레이드**
- `terraform.tfvars`:
  ```hcl
  acr_sku                    = "Standard"
  acr_enable_private_endpoint = true
  ```
- Standard 전환 후 apply 1회면 즉시 PE 생성됨 (다운타임 없음)

---

## 3. Bastion SKU: `Basic`

### 현재 설정
```hcl
bastion_sku = "Basic"
enable_jumpbox = false   # 현재 Authorized IP로 대체
```

### 제약사항 (enable_jumpbox = true 시 적용)

| 항목 | Basic | Standard |
|------|-------|----------|
| Shareable Link | ❌ | ✅ |
| Native Client 지원 | ❌ | ✅ |
| 포트 포워딩 | ❌ | ✅ |
| IP 기반 연결 | ❌ | ✅ |
| 월 비용 | ~$140 | ~$270 |

### 현재 상태
`enable_jumpbox = false` → Bastion/Jumpbox 미배포.
로컬에서 `api_server_authorized_ips`로 kubectl 직접 접근.
Private Cluster 전환 시에만 Bastion 필요.

---

## 4. Private Cluster: `false` (Authorized IP 방식)

### 현재 설정
```hcl
enable_private_cluster    = false
api_server_authorized_ips = ["x.x.x.x/32"]  # 로컬 공인 IP
```

### 제약사항

| 항목 | Authorized IP | Private Cluster |
|------|--------------|----------------|
| API Server 노출 | 공개 인터넷 (IP 필터링) | VNet 내부 전용 |
| kubectl 접근 | 로컬에서 직접 가능 | Jumpbox/VPN 필요 |
| IP 변경 시 | tfvars 업데이트 필요 | 해당 없음 |
| 보안 수준 | 중간 | 높음 |
| 운영 복잡도 | 낮음 | 높음 |

### 구체적 위험
- 공인 IP가 변경되면(유동 IP) API Server 접근 불가 → `api_server_authorized_ips` 업데이트 필요
- CI/CD 파이프라인에서 접근 시 에이전트 IP도 추가 필요
- IP 기반 필터링이므로 해당 IP의 다른 사용자도 접근 가능 (Azure RBAC으로 인가 제어)

### 운영 전환 조건
- 금융/의료/공공 등 높은 보안 요구 시
  ```hcl
  enable_private_cluster = true
  enable_jumpbox         = true
  ```

---

## 5. Karpenter NodePool: OperationalStore 단기 보존

### 현재 설정
```hcl
backup_retention_duration = "P7D"   # 7일
```

### 제약사항
- OperationalStore 최대 보존 기간: **30일**
- VaultStore(장기 보존) 경로 미구성
- 재해 복구(DR) 시나리오에서 30일 이상 이전 데이터 복원 불가

### 운영 전환 조건
- 장기 보존 필요 시 VaultStore 정책 추가 (Terraform 확장 필요)

---

## 6. Ingress Spot 인스턴스: 비활성화

### 현재 설정
```hcl
ingress_spot_enabled = false
```

### 제약사항
- Spot 미사용 → 인그레스 노드 비용 ~80% 높음
- Regular 온디맨드이므로 Eviction 없음 → 안정성 높음

### Spot 활성화 조건
```bash
# lowPriorityCores 쿼터 확인 (최소 6 vCPU 필요 — D2s_v4×3)
az quota show \
  --scope /subscriptions/<SUB>/providers/Microsoft.Compute/locations/koreacentral \
  --resource-name lowPriorityCores
```
쿼터 충족 시: `ingress_spot_enabled = true`

---

## 7. 모니터링: Grafana 비활성화

### 현재 설정
```hcl
enable_grafana = false
```

### 제약사항
- Prometheus 메트릭 수집은 동작하지만 Grafana 대시보드 없음
- `kubectl port-forward`로 임시 조회 필요

### 활성화 조건
```hcl
enable_grafana = true
grafana_sku    = "Essential"   # ~$9/월 (Standard: ~$65/월)
```

---

## 운영 전환 체크리스트

```
□ aks_sku_tier = "Standard"               # SLA 필수
□ acr_sku = "Standard"                    # Private Endpoint 필요 시
□ acr_enable_private_endpoint = true      # 이미지 내부망 pull
□ enable_grafana = true                   # 모니터링 가시성
□ api_server_authorized_ips 주기적 검토   # CI/CD IP 포함 여부
□ backup_retention_duration 검토          # 30일 이내 OperationalStore 또는 VaultStore 추가
□ ingress_spot_enabled 쿼터 확인 후 결정
□ keyvault_purge_protection = true        # 운영 Key Vault 보호
□ backup_soft_delete = true               # 백업 데이터 즉시 삭제 방지
```
