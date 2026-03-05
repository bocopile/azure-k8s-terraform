# 다음 작업 목록 (2026-03-05 업데이트)

## 완료된 작업

### 배포 관련
- [x] DSv4 쿼터 20 → 32 증가 (`az quota update`)
- [x] Total Regional vCPU 20 → 50 증가
- [x] ingress 노드풀 Spot → Regular 전환 (LowPriorityCores 쿼터 부족 대응)
- [x] AKS Diagnostic Setting 3개 `tofu import` 등록
- [x] 배포 완료 (113개 리소스, k8s v1.35.0)
- [x] 배포 후 모니터링 체크리스트 완료 — 전체 이상 없음

### 코드 / 문서
- [x] `pre-destroy.sh` — `az aks command invoke` 방식 전환 (VPN 불필요)
- [x] `DESTROY.md` — 수동 정리 명령어 업데이트
- [x] `README.md` — 배포 후 모니터링 + 크리티컬 장애 대응 섹션 추가
- [x] `README.md` — subscription_id / tenant_id 조회 명령어 보강
- [x] `README.md` — 인프라 삭제 섹션에 pre-destroy.sh 단계 추가

---

## 향후 작업 (우선순위순)

### P1. Remote Backend — Azure Blob Storage
- Terraform state를 Azure Blob Storage에 저장
- RBAC 기반 접근 제어 + state locking
- Storage Account + Container 생성 → backend.tf 설정
- 현재 로컬 state(`terraform.tfstate`)를 원격으로 이전

### P2. Custom Script Extension — Addon 자동 설치
- `azurerm_virtual_machine_extension`으로 Jump VM에서 addon 스크립트 자동 실행
- AKS 생성 후 `depends_on`으로 순서 보장
- Private 클러스터 환경에서도 동작 (Azure 내부 통신)

### P3. 리소스 네이밍 개선
- 지역 이름(koreacentral 등)을 네이밍에서 제거
- 리소스 그룹명 포함 전체 네이밍을 고정(하드코딩) 방식으로 변경
- 전체 삭제 후 재생성이 용이한 구조

### P4. AKS 노드 OS → Azure Linux (Mariner)
- `default_node_pool`에 `os_sku = "AzureLinux"` 추가
- Ingress node pool에도 동일 적용
- Microsoft 최적화, 보안 강화, 빠른 부팅, 작은 이미지

### P5. Azure Redis, MySQL, RabbitMQ 추가
- modules/data-services/ 새 모듈 생성
- Redis: Azure Cache for Redis + Private Endpoint (snet-pe)
- MySQL: Azure Database for MySQL Flexible Server + VNet Integration
- RabbitMQ: AKS 내 Helm(bitnami) 배포 또는 Azure Service Bus로 대체
- Private DNS Zone 추가 (redis, mysql)
