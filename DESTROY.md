# 리소스 삭제 가이드

> **대상**: `tofu apply`로 생성된 ~109개 리소스 + Phase 2 Addon 리소스
> **주의**: 이 가이드의 명령어는 **리소스를 영구 삭제**한다. 실행 전 반드시 확인할 것.

---

## 1. 삭제 순서 요약

```
Step 1: Phase 2 Addon 리소스 정리 (K8s 레벨)
Step 2: tofu destroy (Phase 1 인프라)
Step 3: Key Vault Purge (soft-delete 잔여)
Step 4: 잔여 리소스 확인 및 수동 정리
```

> `tofu destroy`는 state 기반 역순 삭제로 의존성을 자동 처리한다.
> 단, **state 외부에서 생성된 리소스**(K8s Service → Azure LB, PV → Azure Disk 등)는
> 사전 정리가 필요하다.

---

## 2. Step 1 — Phase 2 Addon 리소스 정리

`tofu destroy` 실행 전에 K8s가 생성한 Azure 리소스를 정리해야 한다.
자동화 스크립트를 제공한다:

```bash
# Jump VM 또는 VPN 접속 환경에서 실행
chmod +x scripts/pre-destroy.sh
./scripts/pre-destroy.sh [--cluster all] [--prefix k8s-demo] [--dry-run]
```

### 수동 정리가 필요한 경우

```bash
# 각 클러스터에 대해 실행 (mgmt, app1, app2)
CLUSTER="mgmt"
RG="rg-k8s-demo-${CLUSTER}"
AKS="aks-${CLUSTER}"

az aks get-credentials -g "${RG}" -n "${AKS}"

# 1) LoadBalancer 타입 Service 삭제 (Azure LB 자동 제거)
kubectl delete svc --all-namespaces -l type=LoadBalancer --ignore-not-found

# 2) PersistentVolumeClaim 삭제 (Azure Disk/File 해제)
kubectl delete pvc --all-namespaces --all --ignore-not-found

# 3) Flux GitOps Extension 제거
az k8s-extension delete -g "${RG}" -c "${AKS}" \
  --cluster-type managedClusters -n flux --yes 2>/dev/null || true

# 4) AKS Backup Extension 제거
az k8s-extension delete -g "${RG}" -c "${AKS}" \
  --cluster-type managedClusters -n azure-aks-backup --yes 2>/dev/null || true

# 5) Backup Instance 삭제 (Backup Vault에서)
# Backup Instance가 있으면 Vault 삭제가 차단됨
az dataprotection backup-instance list \
  -g rg-k8s-demo-common --vault-name bv-k8s-demo -o table
# 있다면: az dataprotection backup-instance delete ...
```

---

## 3. Step 2 — tofu destroy

```bash
# 1) 실행 계획 확인 (삭제 대상 리소스 목록 검토)
tofu plan -destroy

# 2) 삭제 실행
tofu destroy

# 예상 출력:
# Destroy complete! Resources: ~109 destroyed.
```

### 삭제 시 알려진 지연

| 리소스 | 예상 소요 시간 | 비고 |
|--------|-------------|------|
| AKS 클러스터 (×3) | 5~10분/개 | MC_* RG 연동 삭제 포함 |
| Azure Bastion | 3~5분 | PIP 연동 삭제 |
| VNet Peering (×6) | 1~2분 | 양방향 해제 |
| Private Endpoint | 1~2분 | DNS 레코드 연동 삭제 |

### 삭제 실패 시 대응

```bash
# 특정 리소스가 삭제 실패 시 해당 리소스만 state에서 제거 후 재시도
# (최후 수단 — 수동 삭제 후 사용)
tofu state rm <resource_address>

# 전체 state 확인
tofu state list
```

---

## 4. Step 3 — Key Vault Purge

Azure Key Vault는 `soft_delete_retention_days = 90`으로 설정되어 있어
`tofu destroy` 후에도 **soft-deleted 상태로 90일간 보존**된다.

### 동일 이름으로 재생성 시 문제

soft-deleted 상태의 Key Vault와 이름이 충돌하면 `tofu apply` 시 오류가 발생한다.
해결 방법은 2가지:

```bash
# 방법 1: Purge (영구 삭제) — purge_protection이 false인 경우만 가능
az keyvault purge --name kv-k8s-demo-<suffix>

# 방법 2: Recover (복구 후 재사용)
az keyvault recover --name kv-k8s-demo-<suffix>
```

### purge_protection 설정 확인

```bash
# 현재 설정 확인
az keyvault show --name kv-k8s-demo-<suffix> --query "properties.enablePurgeProtection"

# purge_protection = true (prod)인 경우:
#   → purge 불가, 90일 대기 후 자동 삭제
#   → 재생성 시 kv_suffix 값을 변경하여 새 이름 사용
#
# purge_protection = false (demo)인 경우:
#   → az keyvault purge 명령으로 즉시 영구 삭제 가능
```

> **provider 설정**: `main.tf`의 `purge_soft_delete_on_destroy = false`는
> Terraform destroy 시 KV를 purge하지 않겠다는 의미다.
> Demo 환경에서 완전 삭제를 원하면 `true`로 변경 가능하나,
> 실수로 인한 데이터 손실 위험이 있으므로 기본값 `false` 유지를 권장한다.

---

## 5. Step 4 — 잔여 리소스 확인

`tofu destroy` 완료 후 아래 명령으로 잔여 리소스를 확인한다.

```bash
# Resource Group 확인 (모두 삭제되었는지)
az group list --query "[?starts_with(name, 'rg-k8s-demo')]" -o table

# MC_* 노드 리소스 그룹 확인 (AKS 삭제 시 자동 제거)
az group list --query "[?starts_with(name, 'MC_rg-k8s-demo')]" -o table

# Soft-deleted Key Vault 확인
az keyvault list-deleted --query "[?starts_with(name, 'kv-k8s-demo')]" -o table

# Network Watcher (리전당 1개, 다른 프로젝트와 공유 가능)
az network watcher list -o table

# 활동 로그 확인 (삭제 이벤트)
az monitor activity-log list \
  --start-time "$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')" \
  --query "[?operationName.value=='Microsoft.Resources/subscriptions/resourceGroups/delete']" \
  -o table
```

---

## 6. 완전 초기화 (모든 흔적 제거)

```bash
# 1) Key Vault purge
az keyvault purge --name kv-k8s-demo-<suffix>

# 2) 로컬 state 파일 삭제
rm -f terraform.tfstate terraform.tfstate.backup

# 3) .terraform 디렉토리 삭제 (provider 캐시)
rm -rf .terraform

# 4) 처음부터 재시작
tofu init
tofu plan
```

---

## 7. 삭제 불가 / 주의 리소스 요약

| 리소스 | 원인 | 대응 |
|--------|------|------|
| Key Vault (soft-deleted) | Azure 정책: 90일 보존 | `az keyvault purge` 또는 `kv_suffix` 변경 |
| Backup Vault (soft-delete=On) | prod 설정 시 보존 | `backup_soft_delete = false`로 전환 후 재삭제 |
| Backup Instance | state 외부 (Addon 생성) | 수동 삭제 또는 `pre-destroy.sh` 실행 |
| Azure LB (K8s Service) | state 외부 (AKS 생성) | K8s Service 삭제 후 자동 제거 |
| Azure Disk (PV) | state 외부 (AKS 생성) | PVC 삭제 후 자동 제거 |
| MC_* RG | AKS 자동 생성 | AKS 삭제 시 연동 삭제 |
| Karpenter 노드 | NAP 자동 프로비저닝 | AKS 삭제 시 자동 회수 |
