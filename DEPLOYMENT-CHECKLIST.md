# 배포 체크리스트 — tofu init부터 인프라 검증까지

> Azure AKS 멀티클러스터(mgmt / app1 / app2) 전체 배포 및 검증 절차

---

## 0. 사전 준비

### 도구 설치 확인

| 도구 | 최소 버전 | 확인 명령 |
|------|-----------|-----------|
| OpenTofu | 1.11.0 | `tofu version` |
| Azure CLI | 2.60 | `az version` |
| Git | - | `git --version` |

### Azure 로그인

```bash
az login
az account set --subscription <SUBSCRIPTION_ID>
az account show   # 구독 확인
```

### terraform.tfvars 준비

```bash
cp terraform.tfvars.example terraform.tfvars
```

필수 입력 항목:

| 변수 | 설명 | 예시 |
|------|------|------|
| `subscription_id` | Azure 구독 ID | `az account show --query id -o tsv` |
| `tenant_id` | Azure 테넌트 ID | `az account show --query tenantId -o tsv` |
| `acr_name` | ACR 이름 (전역 고유) | `mycompanyacr` |
| `kv_suffix` | Key Vault 접미사 (3-8자) | `abc123` |
| `jumpbox_ssh_public_key` | Jump VM SSH 공개키 | `cat ~/.ssh/id_rsa.pub` |
| `kv_allowed_ips` | Terraform 실행 IP (CIDR) | `["$(curl -s ifconfig.me)/32"]` |

> **주의**: `kv_allowed_ips` 미설정 시 data_services 시크릿 쓰기가 403으로 실패

---

## 1. Backend 초기화

### 1-1. Backend 스토리지 생성 및 RBAC 대기

```bash
./scripts/init-backend.sh
```

내부 동작:
1. `backend.tf`에서 스토리지 계정/컨테이너 이름 파싱
2. 스토리지 계정 없으면 자동 생성
3. `Storage Blob Data Contributor` 역할 할당
4. RBAC 전파 대기 (최대 5분, Method B: 실시간 폴링)
5. RBAC 실패 시 Storage Key 방식 fallback (Method A)
6. `tofu init` 실행

### 확인 항목

- [ ] `tofu init` 성공
- [ ] Backend가 Azure Blob Storage로 설정됨 (`backend.tf` 확인)
- [ ] `.terraform/` 디렉토리 생성됨

---

## 2. Azure Provider 등록 확인

```bash
# 필수 Namespace 등록 여부 확인
for ns in \
  Microsoft.ContainerService \
  Microsoft.Network \
  Microsoft.KeyVault \
  Microsoft.ContainerRegistry \
  Microsoft.ManagedIdentity \
  Microsoft.Monitor \
  Microsoft.Dashboard \
  Microsoft.DataProtection \
  Microsoft.KubernetesConfiguration \
  Microsoft.Storage \
  Microsoft.Cache \
  Microsoft.DBforMySQL \
  Microsoft.ServiceBus; do
  state=$(az provider show --namespace "$ns" --query "registrationState" -o tsv 2>/dev/null)
  echo "$ns: $state"
done
```

- [ ] 모든 Namespace가 `Registered` 상태
- 미등록 시: `az provider register --namespace <NAMESPACE> --wait`

---

## 3. Plan 검토

```bash
tofu plan -out=tfplan 2>&1 | tail -5
```

예상 출력: `Plan: N to add, 0 to change, 0 to destroy.`

### 확인 항목

- [ ] Plan 오류 없음
- [ ] `destroy` 항목이 예상치 않게 많지 않음

---

## 4. Apply 실행

```bash
tofu apply tfplan
```

### 예상 소요 시간

| 단계 | 소요 시간 |
|------|-----------|
| Network / RG / Monitoring | 3-5분 |
| AKS 클러스터 3개 | 10-15분 |
| Backup Extension 설치 | 5-7분 |
| jumpbox cloud-init (az CLI + kubectl + addon 통합) | 10-15분 |
| **전체** | **약 28-42분** |

### 자주 발생하는 오류와 조치

| 오류 | 원인 | 조치 |
|------|------|------|
| KV 403 `ForbiddenByConnection` | `kv_allowed_ips` 미설정 | terraform.tfvars에 IP 추가 |
| ServiceBus 409 `MissingSubscriptionRegistration` | Microsoft.KubernetesConfiguration 미등록 | `az provider register --namespace Microsoft.KubernetesConfiguration --wait` |
| jumpbox cloud-init 실패 | apt lock 충돌 또는 MSI 전파 지연 | VM 재부팅 또는 `/var/log/jumpvm-init.log` 확인 |
| State Lock | 이전 apply 중단 | `tofu force-unlock -force <LOCK_ID>` |

---

## 5. 인프라 리소스 존재 여부 검증

```bash
./check-resources.sh \
  --prefix k8s \
  --location koreacentral \
  --acr-name <ACR_NAME> \
  --kv-suffix <KV_SUFFIX>
```

### 확인 항목

- [ ] Resource Groups (4개): rg-k8s-common, rg-k8s-mgmt, rg-k8s-app1, rg-k8s-app2
- [ ] VNet (3개): vnet-mgmt, vnet-app1, vnet-app2
- [ ] NSG (5개): aks-mgmt/app1/app2, bastion, jumpbox
- [ ] Private DNS Zone: `privatelink.koreacentral.azmk8s.io`
- [ ] Monitoring: Log Analytics, Monitor Workspace, App Insights, Grafana
- [ ] ACR, Managed Identities (9개)
- [ ] AKS Clusters (3개): Succeeded 상태
- [ ] Backup Vault
- [ ] Storage Accounts (Flow Logs, Backup Staging)
- [ ] Jumpbox VM + Bastion (rg-k8s-mgmt)

---

## 6. 네트워크 연결 검증

### VNet 피어링 상태

```bash
for vnet in mgmt app1 app2; do
  echo "--- vnet-${vnet} ---"
  az network vnet peering list \
    --resource-group rg-k8s-common \
    --vnet-name vnet-${vnet} \
    --query "[].{name:name, state:peeringState}" \
    -o table
done
```

- [ ] mgmt ↔ app1: `Connected`
- [ ] mgmt ↔ app2: `Connected`
- [ ] app1 ↔ app2: `Connected`

### Private DNS Zone VNet 링크

```bash
for zone in "privatelink.koreacentral.azmk8s.io" "privatelink.vaultcore.azure.net"; do
  echo "--- ${zone} ---"
  az network private-dns link vnet list \
    --resource-group rg-k8s-common \
    --zone-name "${zone}" \
    --query "[].{name:name, vnet:virtualNetwork.id}" \
    -o table
done
```

- [ ] AKS DNS Zone: mgmt, app1, app2 VNet 링크 (3개)
- [ ] KV DNS Zone: mgmt, app1, app2 VNet 링크 (3개)

---

## 7. AKS 클러스터 상태 검증

### 노드풀 상태

```bash
for cluster in mgmt app1 app2; do
  echo "--- aks-${cluster} ---"
  az aks nodepool list \
    --resource-group rg-k8s-${cluster} \
    --cluster-name aks-${cluster} \
    --query "[].{name:name, state:provisioningState, count:count, vmSize:vmSize}" \
    -o table
done
```

예상 결과:
- mgmt: system(3) + ingress(3)
- app1: system(3) + ingress(3)
- app2: system(3) — ingress 없음 (설계 의도)

- [ ] 모든 nodepool `Succeeded`
- [ ] Managed Identity: Monitoring + Azure Monitor Metrics 활성화

```bash
for cluster in mgmt app1 app2; do
  az aks show \
    --resource-group rg-k8s-${cluster} \
    --name aks-${cluster} \
    --query "{omsAgent:addonProfiles.omsagent.enabled, azureMonitor:azureMonitorProfile.metrics.enabled}" \
    -o table
done
```

- [ ] `omsAgent: true`, `azureMonitor: true` (3개 클러스터 모두)

---

## 8. Grafana 데이터 수집 검증

### Grafana 엔드포인트 확인

```bash
tofu output grafana_endpoint
```

브라우저에서 접속: `https://grafana-k8s-*.sel.grafana.azure.com`

### 확인 항목

- [ ] Grafana 대시보드 접속 가능
- [ ] Data Source: Azure Monitor Managed Service for Prometheus 연결됨
- [ ] 대시보드 → Kubernetes / Compute Resources / Cluster에서 메트릭 수집 확인
- [ ] 3개 클러스터(mgmt/app1/app2) 모두 메트릭 표시

> AKS가 활성화된 후 메트릭 수집까지 약 5-10분 소요

---

## 9. Key Vault 검증

### Private Endpoint 확인

```bash
tofu output key_vault_private_endpoint_ip
# 예상: 10.1.5.4 (pe-subnet)
```

### 시크릿 목록 확인

```bash
# kv_allowed_ips에 현재 IP가 있는 경우:
az keyvault secret list \
  --vault-name kv-k8s-<KV_SUFFIX> \
  --query "[].name" \
  -o tsv
```

- [ ] flux-ssh-private-key (flux 설정 시)
- [ ] redis-connection-string, redis-host, redis-primary-key (Redis 활성화 시)
- [ ] mysql-admin-password, mysql-connection-string (MySQL 활성화 시)
- [ ] servicebus-connection-string, servicebus-endpoint (ServiceBus 활성화 시)

---

## 10. Backup 검증

```bash
az dataprotection backup-instance list \
  --resource-group rg-k8s-common \
  --vault-name bv-k8s \
  --query "[].{name:name, state:properties.currentProtectionState}" \
  -o table
```

- [ ] bi-aks-mgmt / bi-aks-app1 / bi-aks-app2: `ProtectionConfigured`

> **참고**: Extension MSI RBAC 전파에 수 분 소요. `ProtectionError` 상태면 5-10분 후 재확인.

---

## 11. Jumpbox 연결 테스트 (선택사항)

```bash
# Bastion으로 접속 (Azure Portal → Bastion → Connect)
# 또는:
az network bastion ssh \
  --resource-group rg-k8s-mgmt \
  --name bastion-k8s \
  --target-resource-id <JUMPBOX_VM_ID> \
  --auth-type ssh-key \
  --username azureadmin \
  --ssh-key ~/.ssh/id_rsa_jumpbox
```

접속 후 확인:
```bash
# AKS 접속 테스트
kubectl get nodes --all-namespaces --kubeconfig ~/.kube/config
# Helm, az CLI 확인
helm version
az aks list -o table
```

- [ ] Jumpbox SSH 접속 성공
- [ ] kubectl로 AKS 노드 조회 가능
- [ ] cloud-init 완료: `cat /tmp/jumpvm-init.done`
- [ ] addon install 완료: `cat /var/log/jumpvm-addon.log`

---

## 12. 최종 확인

```bash
# 잔여 변경사항 없음 확인
tofu plan 2>&1 | tail -3
# 예상: Plan: 0 to add, 0 to change, 0 to destroy.
```

- [ ] `tofu plan` → no changes
- [ ] 모든 체크리스트 항목 완료

---

## 주요 에러 레퍼런스

| 에러 코드 | 설명 |
|-----------|------|
| `ForbiddenByConnection` | KV `public_network_access_enabled = false` + IP 미허용 |
| `ForbiddenByFirewall` | KV `kv_allowed_ips`에 현재 IP 미포함 |
| `MissingSubscriptionRegistration` | Azure Provider Namespace 미등록 |
| `UserErrorMissingMSIPermissionsOnSnapshotResourceGroup` | Backup Extension MSI에 Contributor 역할 없음 |
| `UserErrorInvalidBackupDatasourceParameters` | backup_datasource_parameters 블록 없음 |
| `context deadline exceeded` | Terraform Provider 내부 타임아웃 (30분 초과) |
| State Lock | 이전 apply 비정상 종료로 Lock 잔존 |

---

## 참고 문서

- [README.md](README.md) — 전체 배포 가이드
- [ARCHITECTURE.md](ARCHITECTURE.md) — 인프라 아키텍처
- [DESTROY.md](DESTROY.md) — 리소스 삭제 절차
- [NEXT-STEPS.md](NEXT-STEPS.md) — 다음 단계 작업
