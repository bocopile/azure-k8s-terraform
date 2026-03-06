# Data Services 가이드 (P5 과제)

Azure 관리형 데이터 서비스(Redis / MySQL / Service Bus)의 설계, 배포 방법, 운영 고려사항을 정리한다.

> **현재 상태**: 코드 구현 완료, 플래그(`enable_*`)로 비활성화 상태.
> 재배포 전 아래 체크리스트를 검토한 뒤 활성화한다.

---

## 1. 아키텍처 개요

```
┌─────────────────────────────────────────────────────┐
│  snet-private-endpoints (10.1.3.0/24, mgmt VNet)   │
│                                                     │
│  pe-redis-k8s  ──→ Redis Premium (6GB)              │
│  pe-mysql-k8s  ──→ MySQL Flexible Server            │
│  pe-sb-k8s     ──→ Service Bus Premium              │
└─────────────────────────────────────────────────────┘
         │ Private DNS Zone VNet Link
         ▼ (mgmt / app1 / app2 VNet 모두 링크됨)
┌────────────────────────────────────────────┐
│  Private DNS Zones                         │
│  privatelink.redis.cache.windows.net       │
│  privatelink.mysql.database.azure.com      │
│  privatelink.servicebus.windows.net        │
└────────────────────────────────────────────┘
         │ Connection String → Key Vault Secret
         ▼
┌──────────────────────────────────────────────────────────┐
│  Key Vault (kv-k8s-{suffix})                             │
│  redis-connection-string  / redis-primary-key            │
│  mysql-connection-string  / mysql-admin-password         │
│  servicebus-connection-string / servicebus-endpoint      │
└──────────────────────────────────────────────────────────┘
         │ External Secrets Operator (Workload Identity)
         ▼
   K8s Secret → 앱 컨테이너 주입
```

**공통 패턴:**
- 모든 서비스: Public Network Access `Disabled`, Private Endpoint 전용
- Private DNS Zone → mgmt/app1/app2 VNet 3개 링크
- Connection String → Key Vault Secret 자동 저장 (`secrets.tf`)
- 앱은 External Secrets Operator로 KV에서 Secret 조회 (Workload Identity 인증)

---

## 2. 서비스별 상세

### 2-1. Azure Cache for Redis (Premium)

| 항목 | 값 |
|------|----|
| SKU | Premium (P1 기본) |
| 용량 | P1=6GB / P2=13GB / P3=26GB |
| Zone Redundant | Zone 1/2/3 |
| 지속성 | AOF `false` (기본) → 운영 시 `true` 고려 |
| 예상 비용 | P1: ~$210/월 |

**Key Vault Secrets:**
| Secret 이름 | 내용 |
|-------------|------|
| `redis-connection-string` | Primary connection string (SSL) |
| `redis-host` | Hostname (private endpoint 경유) |
| `redis-primary-key` | Primary access key |

**활성화:**
```hcl
# terraform.tfvars
enable_redis   = true
redis_capacity = 1   # 1=6GB, 2=13GB, 3=26GB
```

**운영 전환 시 추가 검토:**
- `aof_backup_enabled = true` — 재시작 후 데이터 복구 (변수화 필요)
- Geo-replication — DR 요건 시 Premium 복제본 추가

---

### 2-2. Azure Database for MySQL Flexible Server

| 항목 | 값 |
|------|----|
| 버전 | 8.0.21 (기본) |
| SKU (dev) | B_Standard_B2ms (2vCPU/8GB) |
| SKU (prod) | GP_Standard_D4ds_v4 이상 권장 |
| 스토리지 | 20GB (기본, Auto Grow 활성화) |
| Backup | 7일 보존, Geo-redundancy `false` |
| Zone | Zone 1 고정 |
| 예상 비용 | B_Standard_B2ms: ~$41/월 |

**Key Vault Secrets:**
| Secret 이름 | 내용 |
|-------------|------|
| `mysql-admin-password` | 자동 생성 24자 비밀번호 |
| `mysql-connection-string` | JDBC/ADO.NET 형식 Connection String |

**활성화:**
```hcl
# terraform.tfvars
enable_mysql      = true
mysql_sku_name    = "B_Standard_B2ms"
mysql_databases   = ["app_db", "auth_db"]
```

**운영 전환 시 추가 검토:**
- `mysql_sku_name = "GP_Standard_D4ds_v4"` — 운영 워크로드 권장
- `geo_redundant_backup_enabled = true` — DR 요건 시 (변수화 필요)
- `mysql_storage_gb` — 예상 데이터 크기 × 1.5 여유율로 설정
- MySQL 파라미터 튜닝 (`slow_query_log`, `innodb_buffer_pool_size` 등)

---

### 2-3. Azure Service Bus (Premium)

| 항목 | 값 |
|------|----|
| SKU | Premium (Private Endpoint 필수) |
| Capacity Units | 1CU 기본 (1/2/4/8 선택) |
| Partitions | 1 (고정) |
| Dead Letter Queue | 활성화 (max_delivery_count=10) |
| Lock Duration | PT1M (1분) |
| 예상 비용 | 1CU: ~$667/월 ← **최대 비용 항목** |

**Key Vault Secrets:**
| Secret 이름 | 내용 |
|-------------|------|
| `servicebus-connection-string` | Listen+Send 권한 Connection String |
| `servicebus-endpoint` | `sb://<namespace>.servicebus.windows.net/` |

> **비용 주의**: Service Bus Premium은 월 $667 고정 비용 발생.
> 필요 없으면 활성화하지 않는 것이 비용 측면에서 유리하다.
> RabbitMQ self-hosted (Karpenter Spot 노드)와 비교 검토 권장.

**활성화:**
```hcl
# terraform.tfvars
enable_servicebus   = true
servicebus_capacity = 1
servicebus_queues   = ["order-queue", "notification-queue"]
servicebus_topics   = ["events", "audit-log"]
```

**운영 전환 시 추가 검토:**
- Capacity Units — 메시지 처리량(TPS) 기준으로 조정 (1CU ≈ 1,000 TPS)
- Topic Subscriptions — `azurerm_servicebus_subscription` 추가 (현재 미구현)
- Message TTL, Max Size 등 Queue/Topic 세부 설정 조정

---

## 3. 비용 요약

| 서비스 | SKU/사양 | 월 비용 (Korea Central) |
|--------|----------|------------------------|
| Redis | Premium P1 (6GB) | ~$210 |
| MySQL | B_Standard_B2ms | ~$41 |
| Service Bus | Premium 1CU | ~$667 |
| **합계** | | **~$920/월** |

> 비용은 Azure Pricing Calculator 기준 추정치.
> 실제 비용은 트래픽/저장 용량에 따라 변동.

---

## 4. 앱에서 Secret 사용 방법

External Secrets Operator + Workload Identity 패턴:

```yaml
# ExternalSecret 예시 (Redis)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: redis-secret
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-kv-store
    kind: ClusterSecretStore
  target:
    name: redis-secret
  data:
    - secretKey: connection-string
      remoteRef:
        key: redis-connection-string
```

```yaml
# ExternalSecret 예시 (MySQL)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mysql-secret
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-kv-store
    kind: ClusterSecretStore
  target:
    name: mysql-secret
  data:
    - secretKey: connection-string
      remoteRef:
        key: mysql-connection-string
    - secretKey: password
      remoteRef:
        key: mysql-admin-password
```

---

## 5. 배포 절차

```bash
# 1. terraform.tfvars에서 활성화
enable_redis      = true
enable_mysql      = true
enable_servicebus = true   # 비용 주의

# 2. 로컬 공인 IP를 KV 접근 허용 목록에 추가 (시크릿 쓰기 권한)
kv_allowed_ips = ["<your-public-ip>/32"]

# 3. 적용
tofu plan -out=tfplan 2>&1 | tee tofu-plan-$(date +%Y%m%d-%H%M%S).log
tofu apply tfplan 2>&1 | tee tofu-apply-$(date +%Y%m%d-%H%M%S).log

# 4. Key Vault Secret 확인
az keyvault secret list --vault-name kv-k8s-9340 -o table
az keyvault secret show --vault-name kv-k8s-9340 --name redis-connection-string --query value -o tsv
```

---

## 6. destroy 시 주의사항

```bash
# Data Services는 destroy 전 앱 연결 해제 필요
# Redis: 연결 중인 앱 종료 후 destroy
# MySQL: 데이터 백업 후 destroy (자동 백업 7일 보존되지만 리소스 삭제 시 함께 삭제)
# Service Bus: 처리 중인 메시지 확인 후 destroy (Dead Letter Queue 포함)

tofu destroy -target=module.data_services
```

---

## 7. 미결 과제 (Next Steps)

- [ ] Service Bus Topic Subscriptions 추가 (`azurerm_servicebus_subscription`)
- [ ] Redis AOF 지속성 변수화 (`aof_backup_enabled`)
- [ ] MySQL geo-redundancy 변수화 (`geo_redundant_backup_enabled`)
- [ ] MySQL 파라미터 그룹 설정 (`azurerm_mysql_flexible_server_configuration`)
- [ ] Redis 캐시 규칙/이벤트 알림 설정 (keyspace notifications)
- [ ] Diagnostic Settings 추가 (Redis/MySQL/ServiceBus → Log Analytics)
- [ ] RabbitMQ vs Service Bus 비용/기능 비교 검토 ($667/월 대비 Spot 노드 활용)
- [ ] 앱별 ClusterSecretStore 설정 (`addons/scripts/03-external-secrets.sh` 연동)
