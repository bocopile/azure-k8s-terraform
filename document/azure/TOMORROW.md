# 내일 할 일 (2026-03-08)

현재 리소스 0개 (전체 destroy 상태). 인프라 재배포 + 전체 점검이 핵심 목표.

---

## 우선순위 요약

| 우선순위 | 작업 | 예상 소요 |
|----------|------|-----------|
| 🔴 P0 | `tofu apply` — 인프라 전체 배포 | 30~60분 |
| 🔴 P0 | 배포 후 인프라 점검 (리소스/네트워크/RBAC) | 30분 |
| 🔴 P0 | Addon 스크립트 순서대로 실행 | 60~90분 |
| 🔴 P0 | Addon 설치 후 전체 동작 검증 | 30~60분 |
| 🟡 P1 | Ingress Spot 쿼터 확인 + 실제 동작 확인 | 10분 |
| 🟡 P1 | mTLS STRICT 실제 동작 확인 | 15분 |
| 🟡 P1 | Backup Instance 연결 상태 확인 | 10분 |
| 🟢 P2 | Tetragon + Managed Cilium 충돌 여부 검증 | 20분 |

---

## Step 1. 배포 전 사전 확인

```bash
# 1-1. Soft-deleted KV 충돌 여부 확인 (kv-k8s-9340은 신규 — 충돌 없음)
az keyvault list-deleted --query "[].name" -o tsv

# 1-2. Spot 쿼터 확인 (ingress_spot_enabled = true 사용 시 필수)
az quota show \
  --scope /subscriptions/75da2b99-60a8-4d84-9119-df4a2cfdcea8/providers/Microsoft.Compute/locations/koreacentral \
  --resource-name lowPriorityCores
# currentValue < limit 여야 Spot 배포 가능
# 부족 시: ingress_spot_enabled = false 로 변경 후 진행

# 1-3. DSv4 쿼터 확인 (system/ingress 노드풀용)
az quota show \
  --scope /subscriptions/75da2b99-60a8-4d84-9119-df4a2cfdcea8/providers/Microsoft.Compute/locations/koreacentral \
  --resource-name standardDSv4Family

# 1-4. 현재 공인 IP → kv_allowed_ips 최신화 (terraform.tfvars)
curl -s ifconfig.me
# terraform.tfvars의 kv_allowed_ips = ["<IP>/32"] 업데이트
```

---

## Step 2. tofu apply — 인프라 전체 배포 🔴 핵심

```bash
cd ~/IdeaProjects/azure-k8s-terraform

# 2-1. Backend init
tofu init -reconfigure

# 2-2. Plan 검토 (로그 기록)
tofu plan -out=tfplan 2>&1 | tee tofu-plan-$(date +%Y%m%d-%H%M%S).log

# Plan에서 확인할 항목:
#   - 예상 리소스 수: ~120개 내외
#   - module.data_services 리소스가 0개인지 확인 (enable_* = false)
#   - ingress 노드풀 priority = "Spot" or "Regular" 확인

# 2-3. Apply (로그 기록 — 실패 시 추적용)
tofu apply tfplan 2>&1 | tee tofu-apply-$(date +%Y%m%d-%H%M%S).log
```

**예상 소요**: 30~60분 (AKS 클러스터 3개 + Private Endpoint + Backup Vault 등)

**apply 중 오류 대응:**
- `ResourceQuotaExceeded` → Step 1 쿼터 확인 후 `ingress_spot_enabled = false` 또는 node_count 조정
- `KeyVaultAlreadySoftDeleted` → `az keyvault purge --name kv-k8s-9340 --location koreacentral`
- `PrincipalNotFound` → Service Principal 전파 지연, 수 분 후 재시도

---

## Step 3. 배포 후 인프라 점검 🔴 매우 중요

apply 완료 직후 반드시 확인. 문제가 있으면 이 시점에 발견하는 것이 addon 설치 후보다 훨씬 쉽다.

```bash
# 3-1. 전체 리소스 수 확인
az resource list --subscription 75da2b99-60a8-4d84-9119-df4a2cfdcea8 \
  --query "length(@)" -o tsv
# 예상: 110~130개

# 3-2. AKS 클러스터 3개 상태
az aks list --query "[].{name:name, state:provisioningState, k8s:kubernetesVersion}" -o table
# 모두 provisioningState = Succeeded 확인

# 3-3. 노드풀 상태 (Spot 포함)
for cluster in mgmt app1 app2; do
  echo "=== aks-${cluster} ==="
  az aks nodepool list -g "rg-k8s-${cluster}" --cluster-name "aks-${cluster}" \
    --query "[].{name:name, state:provisioningState, priority:scaleSetPriority, count:count}" -o table
done

# 3-4. VNet 피어링 상태 (mgmt↔app1↔app2 풀메시)
az network vnet peering list -g rg-k8s-common --vnet-name vnet-mgmt -o table

# 3-5. Private DNS Zone 링크 확인
az network private-dns link vnet list -g rg-k8s-common \
  --zone-name "privatelink.azurecr.io" -o table

# 3-6. Key Vault 접근 테스트
az keyvault secret list --vault-name kv-k8s-9340 -o table

# 3-7. check-resources.sh 스크립트 실행
bash ./check-resources.sh
```

**점검 체크리스트:**
- [ ] AKS 3개 클러스터 모두 `Succeeded`
- [ ] 노드풀 노드 수: system=1, ingress=1 (mgmt/app1만)
- [ ] Ingress 노드풀 priority: Spot or Regular (설정대로 확인)
- [ ] VNet 피어링 6개 모두 `Connected`
- [ ] Key Vault secret 목록 조회 성공 (flux-ssh-private-key 포함)
- [ ] Backup Vault / Backup Policy 생성 확인
- [ ] ACR 접근 가능 (`az acr login -n bocopile`)

---

## Step 4. Addon 스크립트 실행

jumpbox 또는 `az aks command invoke`로 실행. 순서 중요.

```bash
# jumpbox 접속 (Bastion 경유)
# Azure Portal → Bastion → jumpbox VM → SSH

# 또는 로컬에서 각 클러스터에 kubectl 자격증명 취득
az aks get-credentials -g rg-k8s-mgmt --name aks-mgmt --overwrite-existing
az aks get-credentials -g rg-k8s-app1 --name aks-app1 --overwrite-existing
az aks get-credentials -g rg-k8s-app2 --name aks-app2 --overwrite-existing
```

### 실행 순서 (각 스크립트는 클러스터명 인수 필요)

| 순서 | 스크립트 | 대상 | 비고 |
|------|----------|------|------|
| 1 | `00-priority-classes.sh` | mgmt, app1, app2 | PriorityClass 생성 |
| 2 | `00b-gateway-api.sh` | mgmt, app1, app2 | Gateway API CRD |
| 3 | `01-cert-manager.sh` | mgmt, app1, app2 | cert-manager + ClusterIssuer |
| 4 | `02-external-secrets.sh` | mgmt, app1, app2 | ESO + ClusterSecretStore |
| 5 | `03-reloader.sh` | mgmt, app1, app2 | Reloader |
| 6 | `04-istio.sh` | mgmt, app1, app2 | AKS Mesh 활성화 (시간 소요) |
| 7 | `04b-istio-mtls.sh` | mgmt, app1, app2 | **mTLS STRICT** |
| 8 | `05-kyverno.sh` | mgmt, app1, app2 | 정책 엔진 |
| 9 | `06-flux.sh` | mgmt | Flux FluxConfig + SSH Key |
| 10 | `07-kiali.sh` | mgmt | Kiali CR |
| 11 | `08-karpenter-nodepool.sh` | mgmt, app1, app2 | Karpenter NodePool (Spot) |
| 12 | `09-backup-extension.sh` | mgmt, app1, app2 | Backup Extension |
| 13 | `10-defender.sh` | mgmt, app1, app2 | Defender |
| 14 | `13-hubble.sh` | mgmt, app1, app2 | Hubble UI |
| 15 | `14-verify-clusters.sh` | mgmt, app1, app2 | **전체 검증** |
| 16 | `15-tetragon.sh` | mgmt, app1, app2 | Tetragon (Cilium 충돌 주의) |
| 17 | `16-otel-collector.sh` | mgmt | OTel Collector |
| 18 | `17-grafana-dashboards.sh` | mgmt | Grafana 대시보드 |
| 19 | `19-vpa.sh` | mgmt, app1, app2 | VPA |

```bash
# 예시 실행
cd ~/IdeaProjects/azure-k8s-terraform/addons/scripts

for cluster in mgmt app1 app2; do
  bash 00-priority-classes.sh ${cluster}
done

for cluster in mgmt app1 app2; do
  bash 00b-gateway-api.sh ${cluster}
done

# ... (순서대로 계속)
```

---

## Step 5. 핵심 검증 항목 🔴

addon 설치 완료 후 반드시 확인.

### 5-1. mTLS STRICT 동작 확인
```bash
# PeerAuthentication 확인
kubectl get peerauthentication -A
# 모든 네임스페이스에 STRICT 모드 적용 확인

# DestinationRule 확인
kubectl get destinationrule -A
# ISTIO_MUTUAL 적용 확인

# 실제 mTLS 테스트 (사이드카 없는 Pod → 서비스 접근 거부되어야 함)
kubectl run test-nomtls --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://kiali.istio-system.svc.cluster.local:20001
# mTLS STRICT 시 접속 실패해야 정상
```

### 5-2. Backup Instance 연결 상태
```bash
az dataprotection backup-instance list \
  --resource-group rg-k8s-common \
  --vault-name bvault-k8s \
  --query "[].{name:name, state:properties.currentProtectionState}" -o table
# ProtectionConfigured 상태여야 정상
```

### 5-3. Tetragon vs Managed Cilium 충돌 여부
```bash
# Tetragon Pod 상태
kubectl get pods -n kube-system -l app.kubernetes.io/name=tetragon

# CrashLoopBackOff 발생 시 → TETRAGON_FORCE=true 없이 설치됐는지 확인
# 충돌 시: helm uninstall tetragon -n kube-system
```

### 5-4. Flux GitOps 동작 확인
```bash
flux get sources git -A
flux get kustomizations -A
# Ready=True 상태 확인
```

### 5-5. cert-manager ClusterIssuer 동작 확인
```bash
kubectl get clusterissuer -A
kubectl describe clusterissuer letsencrypt-http01
# Status: Ready = True 확인
```

### 5-6. 노드 전체 Ready 상태
```bash
for cluster in mgmt app1 app2; do
  echo "=== ${cluster} ==="
  kubectl config use-context aks-${cluster}
  kubectl get nodes -o wide
done
# 모든 노드 STATUS=Ready 확인
```

---

## Step 6. 미결 이슈 처리 (시간 여유 시)

- **Tetragon 충돌 확인 후** `NEXT-STEPS.md` m3 항목 완료 처리
- **Service Bus Topic Subscriptions** 필요 여부 확인 (DATA-SERVICES.md 참조)
- **Data Services 활성화 여부** 결정 후 terraform.tfvars 반영

---

## 참고 로그 명령

```bash
# tofu apply 로그에서 오류만 추출
grep -E "Error:|error:|WARN" tofu-apply-*.log

# AKS 이벤트 확인 (문제 발생 시)
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# 노드 상태 상세 (NotReady 발생 시)
kubectl describe node <node-name>
```
