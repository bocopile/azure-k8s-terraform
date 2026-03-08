#!/usr/bin/env bash
# ============================================================
# post-apply-check.sh — tofu apply 후 인프라 전체 검증
#
# 모든 항목은 WARN 레벨 — 실패해도 스크립트 계속 진행 (exit 0)
# 최종 요약에서 WARN/FAIL 수 출력
#
# Usage: bash scripts/post-apply-check.sh
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS="${ROOT_DIR}/terraform.tfvars"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

log_ok()   { echo -e "  ${GRN}[OK]${NC}   $*";   OK_COUNT=$((OK_COUNT+1)); }
log_warn() { echo -e "  ${YLW}[WARN]${NC} $*"; WARN_COUNT=$((WARN_COUNT+1)); }
log_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
log_info() { echo -e "  ${DIM}       $*${NC}"; }
section()  { echo; echo -e "${BLU}━━━ $* ━━━${NC}"; }

# tfvars 값 추출
tfvar() {
  grep "^[[:space:]]*${1}[[:space:]]*=" "${TFVARS}" | \
    grep -v '^[[:space:]]*#' | \
    sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | \
    tr -d '"' | head -1 | xargs 2>/dev/null || true
}

# ── 설정 읽기 ────────────────────────────────────────────────
SUB=$(tfvar subscription_id)
PREFIX=$(tfvar prefix);         PREFIX="${PREFIX:-k8s}"
KV_SUFFIX=$(tfvar kv_suffix)
KV_NAME="kv-${PREFIX}-${KV_SUFFIX}"
RG_COMMON="rg-${PREFIX}-common"
CLUSTERS=("mgmt" "app1" "app2")
CLUSTERS_WITH_INGRESS=("mgmt" "app1")
LOCATION="koreacentral"
LOG_DIR="${ROOT_DIR}/logs/post-apply-check"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/$(date +%Y%m%d-%H%M%S).log"

echo "============================================================"
echo " post-apply-check.sh — $(date '+%Y-%m-%d %H:%M:%S')"
echo " 로그: ${LOG_FILE}"
echo "============================================================"

# tee로 로그 파일에도 기록
exec > >(tee -a "${LOG_FILE}") 2>&1

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "1. AKS 클러스터 상태"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cluster in "${CLUSTERS[@]}"; do
  RG="rg-${PREFIX}-${cluster}"
  CLUSTER_NAME="aks-${cluster}"

  STATE=$(az aks show -g "${RG}" -n "${CLUSTER_NAME}" \
    --query "provisioningState" -o tsv 2>/dev/null || echo "ERROR")
  K8S_VER=$(az aks show -g "${RG}" -n "${CLUSTER_NAME}" \
    --query "kubernetesVersion" -o tsv 2>/dev/null || echo "")

  if [[ "${STATE}" == "Succeeded" ]]; then
    log_ok "${CLUSTER_NAME}: Succeeded (k8s ${K8S_VER})"
  elif [[ "${STATE}" == "ERROR" ]]; then
    log_fail "${CLUSTER_NAME}: 조회 실패 — 클러스터가 존재하지 않거나 권한 없음"
  else
    log_warn "${CLUSTER_NAME}: ${STATE} — 배포 미완료 또는 오류"
  fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "2. 노드풀 상태"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cluster in "${CLUSTERS[@]}"; do
  RG="rg-${PREFIX}-${cluster}"
  CLUSTER_NAME="aks-${cluster}"

  POOLS=$(az aks nodepool list -g "${RG}" --cluster-name "${CLUSTER_NAME}" \
    --query "[].{name:name, state:provisioningState, priority:scaleSetPriority, count:count}" \
    -o json 2>/dev/null || echo "[]")

  POOL_COUNT=$(echo "${POOLS}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  if [[ "${POOL_COUNT}" == "0" ]]; then
    log_warn "${CLUSTER_NAME}: 노드풀 조회 실패"
    continue
  fi

  echo "${POOLS}" | CLUSTER="${cluster}" python3 -c "
import sys, json, os
cluster = os.environ['CLUSTER']
pools = json.load(sys.stdin)
for p in pools:
    state = p.get('state','?')
    name  = p.get('name','?')
    prio  = p.get('priority','Regular')
    cnt   = p.get('count', 0)
    spot  = ' [Spot]' if prio == 'Spot' else ''
    tag   = '[OK]  ' if state == 'Succeeded' else '[WARN]'
    print(f'  {tag} {cluster}/{name}: {state}, {cnt}노드{spot}')
" 2>/dev/null || log_warn "${CLUSTER_NAME}: 노드풀 상세 파싱 실패"
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "3. VNet 피어링 (풀메시 mgmt↔app1↔app2)"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PEERING_FAIL=0

for vnet_key in mgmt app1 app2; do
  case "${vnet_key}" in
    mgmt) VNET="vnet-mgmt" ;;
    app1) VNET="vnet-app1" ;;
    app2) VNET="vnet-app2" ;;
  esac
  PEERINGS=$(az network vnet peering list -g "${RG_COMMON}" --vnet-name "${VNET}" \
    --query "[].{name:name, state:peeringState}" -o json 2>/dev/null || echo "[]")

  echo "${PEERINGS}" | VNET_KEY="${vnet_key}" python3 -c "
import sys, json, os
vnet_key = os.environ['VNET_KEY']
peers = json.load(sys.stdin)
for p in peers:
    state = p.get('state','?')
    name  = p.get('name','?')
    ok    = state == 'Connected'
    tag   = '[OK]  ' if ok else '[WARN]'
    print(f'  {tag} {vnet_key}/{name}: {state}')
" 2>/dev/null || { log_warn "${VNET}: 피어링 조회 실패"; PEERING_FAIL=$((PEERING_FAIL+1)); }
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "4. Private DNS Zone VNet 링크"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DNS_ZONES=(
  "privatelink.azurecr.io"
  "privatelink.vaultcore.azure.net"
)

for zone in "${DNS_ZONES[@]}"; do
  LINKS=$(az network private-dns link vnet list -g "${RG_COMMON}" --zone-name "${zone}" \
    --query "[].{name:name, state:virtualNetworkLinkState}" -o json 2>/dev/null || echo "[]")
  LINK_COUNT=$(echo "${LINKS}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "${LINK_COUNT}" == "0" ]]; then
    log_warn "DNS Zone ${zone}: VNet 링크 없음 (Private Endpoint 미활성화이면 정상)"
  else
    echo "${LINKS}" | ZONE="${zone}" python3 -c "
import sys, json, os
zone = os.environ['ZONE']
links = json.load(sys.stdin)
ok = all(l.get('state') == 'Completed' for l in links)
count = len(links)
tag = '[OK]  ' if ok else '[WARN]'
states = ', '.join(set(l.get('state','?') for l in links))
print(f'  {tag} {zone}: {count}개 링크 ({states})')
" 2>/dev/null
  fi
done

# AKS Private DNS Zone 링크 (3개 VNet 모두 연결되어야 함)
AKS_DNS_ZONES=$(az network private-dns zone list -g "${RG_COMMON}" \
  --query "[?contains(name, 'privatelink.${LOCATION}.azmk8s.io')].name" \
  -o tsv 2>/dev/null || echo "")

if [[ -z "${AKS_DNS_ZONES}" ]]; then
  log_warn "AKS Private DNS Zone 미확인 — 클러스터가 생성되지 않았을 수 있음"
else
  while IFS= read -r zone; do
    LINK_COUNT=$(az network private-dns link vnet list -g "${RG_COMMON}" --zone-name "${zone}" \
      --query "length(@)" -o tsv 2>/dev/null || echo "0")
    if (( LINK_COUNT >= 3 )); then
      log_ok "AKS DNS Zone ${zone}: ${LINK_COUNT}개 VNet 링크"
    else
      log_warn "AKS DNS Zone ${zone}: VNet 링크 ${LINK_COUNT}개 (3개 필요)"
    fi
  done <<< "${AKS_DNS_ZONES}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "5. Key Vault 접근 및 Secret 존재 여부"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
KV_STATE=$(az keyvault show --name "${KV_NAME}" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "")
if [[ "${KV_STATE}" == "Succeeded" ]]; then
  log_ok "${KV_NAME}: 생성됨"

  SECRETS=$(az keyvault secret list --vault-name "${KV_NAME}" --query "[].name" -o tsv 2>/dev/null || echo "")
  FLUX_KEY_EXISTS=$(echo "${SECRETS}" | grep -c "flux-ssh-private-key" || true)
  [[ "${FLUX_KEY_EXISTS}" -gt 0 ]] && log_ok "Secret: flux-ssh-private-key 존재" \
                                    || log_warn "Secret: flux-ssh-private-key 없음 (flux_ssh_private_key 미설정)"
else
  log_warn "${KV_NAME}: 상태 조회 실패 또는 미생성 (${KV_STATE:-없음})"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "6. ACR 접근"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ACR_NAME=$(tfvar acr_name)
ACR_STATE=$(az acr show --name "${ACR_NAME}" --query "provisioningState" -o tsv 2>/dev/null || echo "")
if [[ "${ACR_STATE}" == "Succeeded" ]]; then
  log_ok "ACR ${ACR_NAME}: 접근 가능"
else
  log_warn "ACR ${ACR_NAME}: 상태 조회 실패 (${ACR_STATE:-없음})"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "7. Backup Vault / Policy"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
VAULT_NAME="bv-${PREFIX}"
BV_STATE=$(az dataprotection backup-vault show -g "${RG_COMMON}" --vault-name "${VAULT_NAME}" \
  --query "properties.provisioningState" -o tsv 2>/dev/null || echo "")
if [[ "${BV_STATE}" == "Succeeded" ]]; then
  log_ok "Backup Vault ${VAULT_NAME}: 생성됨"

  for cluster in "${CLUSTERS[@]}"; do
    RG="rg-${PREFIX}-${cluster}"
    INSTANCE=$(az dataprotection backup-instance list \
      -g "${RG_COMMON}" --vault-name "${VAULT_NAME}" \
      --query "[?properties.dataSourceInfo.resourceName=='aks-${cluster}'].properties.currentProtectionState" \
      -o tsv 2>/dev/null || echo "")
    if [[ "${INSTANCE}" == "ProtectionConfigured" ]]; then
      log_ok "Backup Instance aks-${cluster}: ProtectionConfigured"
    elif [[ -n "${INSTANCE}" ]]; then
      log_warn "Backup Instance aks-${cluster}: ${INSTANCE}"
    else
      log_warn "Backup Instance aks-${cluster}: 미연결 (09-backup-extension.sh 실행 필요)"
    fi
  done
else
  log_warn "Backup Vault ${VAULT_NAME}: ${BV_STATE:-미생성}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "8. K8s 노드 상태 (az aks command invoke)"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cluster in "${CLUSTERS[@]}"; do
  RG="rg-${PREFIX}-${cluster}"
  CLUSTER_NAME="aks-${cluster}"

  echo -e "  ${DIM}--- ${CLUSTER_NAME} ---${NC}"
  _INVOKE_ERR=$(mktemp)
  RESULT=$(az aks command invoke -g "${RG}" -n "${CLUSTER_NAME}" \
    --command "kubectl get nodes --no-headers 2>/dev/null" \
    --query "logs" -o tsv 2>"${_INVOKE_ERR}" || true)
  _ERR_MSG=$(cat "${_INVOKE_ERR}"); rm -f "${_INVOKE_ERR}"

  if [[ -z "$(echo "${RESULT}" | tr -d '[:space:]')" ]]; then
    if echo "${_ERR_MSG}" | grep -q "KubernetesPerformanceError\|Insufficient resources"; then
      log_warn "${CLUSTER_NAME}: command invoke 실패 — 시스템 노드 CPU 부족 (system_node_count 증가 필요)"
    else
      log_warn "${CLUSTER_NAME}: command invoke 실패 (클러스터 미생성 또는 권한 없음)"
    fi
    continue
  fi

  NOT_READY=$(echo "${RESULT}" | grep -v "Ready" | grep -v "^$" | wc -l | xargs)
  READY_COUNT=$(echo "${RESULT}" | grep "Ready" | grep -v "NotReady" | wc -l | xargs)
  TOTAL=$(echo "${RESULT}" | grep -c "." || true)

  if [[ "${NOT_READY}" -eq 0 ]]; then
    log_ok "${CLUSTER_NAME}: 노드 ${READY_COUNT}/${TOTAL} Ready"
  else
    log_warn "${CLUSTER_NAME}: ${NOT_READY}개 노드 NotReady"
    echo "${RESULT}" | grep -v "Ready" | grep -v "^$" | while IFS= read -r line; do
      log_info "  → ${line}"
    done
  fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "9. 시스템 Pod 상태 (kube-system)"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cluster in "${CLUSTERS[@]}"; do
  RG="rg-${PREFIX}-${cluster}"
  CLUSTER_NAME="aks-${cluster}"

  _INVOKE_ERR=$(mktemp)
  RESULT=$(az aks command invoke -g "${RG}" -n "${CLUSTER_NAME}" \
    --command "kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -vE 'Running|Completed|Succeeded'" \
    --query "logs" -o tsv 2>"${_INVOKE_ERR}" || true)
  _ERR_MSG=$(cat "${_INVOKE_ERR}"); rm -f "${_INVOKE_ERR}"

  if [[ -z "${RESULT}" ]] && echo "${_ERR_MSG}" | grep -q "KubernetesPerformanceError\|Insufficient resources"; then
    log_warn "${CLUSTER_NAME}/kube-system: 조회 실패 — 시스템 노드 CPU 부족"
  elif [[ -z "${RESULT}" ]] && echo "${_ERR_MSG}" | grep -q "ERROR\|Error\|error"; then
    log_warn "${CLUSTER_NAME}/kube-system: 조회 실패"
  elif [[ -z "$(echo "${RESULT}" | tr -d '[:space:]')" ]]; then
    log_ok "${CLUSTER_NAME}/kube-system: 모든 Pod 정상"
  else
    ABNORMAL=$(echo "${RESULT}" | grep -c "." || true)
    log_warn "${CLUSTER_NAME}/kube-system: ${ABNORMAL}개 Pod 비정상"
    echo "${RESULT}" | head -5 | while IFS= read -r line; do log_info "  → ${line}"; done
  fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "10. Addon 설치 상태"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

check_addon() {
  local cluster="$1" ns="$2" label="$3" name="$4"
  local RG="rg-${PREFIX}-${cluster}"
  local CMD="kubectl get pods -n ${ns} -l ${label} --no-headers 2>/dev/null | grep -c Running || echo 0"
  local COUNT
  COUNT=$(az aks command invoke -g "${RG}" -n "aks-${cluster}" \
    --command "${CMD}" --query "logs" -o tsv 2>/dev/null | tr -d '[:space:]' || echo "0")
  if [[ "${COUNT}" =~ ^[0-9]+$ ]] && (( COUNT > 0 )); then
    log_ok "${cluster}/${name}: Running Pod ${COUNT}개"
  elif [[ "${COUNT}" == "0" ]]; then
    log_warn "${cluster}/${name}: Running Pod 없음 (addon 미설치)"
  else
    log_warn "${cluster}/${name}: 상태 확인 실패"
  fi
}

check_resource() {
  local cluster="$1" kind="$2" ns_flag="$3" name_label="$4" display="$5"
  local RG="rg-${PREFIX}-${cluster}"
  local CMD="kubectl get ${kind} ${ns_flag} --no-headers 2>/dev/null | wc -l | xargs"
  local COUNT
  COUNT=$(az aks command invoke -g "${RG}" -n "aks-${cluster}" \
    --command "${CMD}" --query "logs" -o tsv 2>/dev/null | tr -d '[:space:]' || echo "0")
  if [[ "${COUNT}" =~ ^[0-9]+$ ]] && (( COUNT > 0 )); then
    log_ok "${cluster}/${display}: ${COUNT}개 존재"
  else
    log_warn "${cluster}/${display}: 없음 (addon 스크립트 실행 필요)"
  fi
}

for cluster in "${CLUSTERS[@]}"; do
  echo -e "  ${DIM}--- aks-${cluster} ---${NC}"
  # cert-manager
  check_addon "${cluster}" "cert-manager" "app.kubernetes.io/name=cert-manager" "cert-manager"
  check_resource "${cluster}" "clusterissuer" "" "" "ClusterIssuer"

  # external-secrets
  check_addon "${cluster}" "external-secrets" "app.kubernetes.io/name=external-secrets" "external-secrets"

  # istio (AKS Managed Mesh)
  ISTIO_STATE=$(az aks show -g "rg-${PREFIX}-${cluster}" -n "aks-${cluster}" \
    --query "serviceMeshProfile.mode" -o tsv 2>/dev/null || echo "")
  [[ "${ISTIO_STATE}" == "Istio" ]] && log_ok "${cluster}/istio: Managed Mesh 활성화" \
                                     || log_warn "${cluster}/istio: Mesh 비활성화 (${ISTIO_STATE:-미확인})"

  # mTLS PeerAuthentication
  check_resource "${cluster}" "peerauthentication" "-A" "" "mTLS PeerAuthentication"

  # karpenter NodePool (NAP)
  check_resource "${cluster}" "nodepool.karpenter.sh" "" "" "Karpenter NodePool"
done

# mgmt 전용 addon
echo -e "  ${DIM}--- mgmt 전용 ---${NC}"
check_addon "mgmt" "flux-system" "app=source-controller" "flux/source-controller"
check_resource "mgmt" "fluxconfig" "-A" "" "FluxConfig"
check_addon "mgmt" "kiali-operator" "app=kiali-operator" "kiali-operator"
check_resource "mgmt" "kiali" "-n istio-system" "" "Kiali CR"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "11. 클러스터 간 네트워크 통신"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# VNet 피어링 Connected 확인은 위(섹션3)에서 완료.
# 여기서는 Pod → 다른 클러스터 VNet IP 도달 가능 여부 검사 (DNS + ICMP)

# system 노드풀 taint(CriticalAddonsOnly)를 허용하는 overrides JSON
_TOLERATION_JSON='{"spec":{"tolerations":[{"key":"CriticalAddonsOnly","operator":"Exists"}]}}'

for cluster in "app1" "app2"; do
  RG="rg-${PREFIX}-${cluster}"
  RESULT=$(az aks command invoke -g "${RG}" -n "aks-${cluster}" \
    --command "kubectl run cross-net-test --image=alpine:3.19 --rm --restart=Never \
      --timeout=30s \
      --overrides='${_TOLERATION_JSON}' \
      -- sh -c 'nslookup kubernetes.default && echo net-ok' 2>/dev/null | tail -3" \
    --query "logs" -o tsv 2>/dev/null || echo "FAILED")

  if echo "${RESULT}" | grep -q "net-ok"; then
    log_ok "${cluster}: 클러스터 내부 DNS 정상"
  else
    log_warn "${cluster}: 내부 DNS 테스트 실패 또는 타임아웃"
  fi
done

# VNet 간 실제 IP 도달 — mgmt에서 app1 첫 번째 system 노드 IP에 ping
# Azure API로 동적 조회 (하드코딩 IP 사용 안 함)
_APP1_NRGROUP=$(az aks show -g "rg-${PREFIX}-app1" -n "aks-app1" \
  --query "nodeResourceGroup" -o tsv 2>/dev/null || echo "")
_APP1_NODE_IP=""
if [[ -n "${_APP1_NRGROUP}" ]]; then
  _APP1_NODE_IP=$(az network nic list -g "${_APP1_NRGROUP}" \
    --query "[?contains(name,'system')].ipConfigurations[0].privateIPAddress | [0]" \
    -o tsv 2>/dev/null | tr -d '[:space:]')
fi

if [[ -z "${_APP1_NODE_IP}" ]]; then
  log_warn "mgmt → app1 VNet ping: app1 노드 IP 조회 실패 (MC_ RG 권한 확인)"
else
  MGMT_TO_APP1=$(az aks command invoke \
    -g "rg-${PREFIX}-mgmt" -n "aks-mgmt" \
    --command "kubectl run ping-test --image=alpine:3.19 --rm --restart=Never \
      --timeout=20s \
      --overrides='${_TOLERATION_JSON}' \
      -- sh -c 'ping -c 2 -W 3 ${_APP1_NODE_IP} 2>&1 | tail -2 && echo ping-ok' 2>/dev/null \
      | tail -3" \
    --query "logs" -o tsv 2>/dev/null || echo "FAILED")

  if echo "${MGMT_TO_APP1}" | grep -q "ping-ok"; then
    log_ok "mgmt → app1 VNet(${_APP1_NODE_IP}) 도달 가능 (VNet 피어링 정상)"
  else
    log_warn "mgmt → app1 VNet(${_APP1_NODE_IP}) ping 실패 (NSG ICMP 차단 가능성)"
    log_info "  → az network vnet peering list -g ${RG_COMMON} --vnet-name vnet-mgmt 확인"
  fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "12. mTLS STRICT 적용 여부"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cluster in "${CLUSTERS[@]}"; do
  RG="rg-${PREFIX}-${cluster}"
  CMD="kubectl get peerauthentication -A --no-headers 2>/dev/null \
    | grep -c STRICT || echo 0"
  COUNT=$(az aks command invoke -g "${RG}" -n "aks-${cluster}" \
    --command "${CMD}" --query "logs" -o tsv 2>/dev/null | tr -d '[:space:]' || echo "0")

  if [[ "${COUNT}" =~ ^[0-9]+$ ]] && (( COUNT > 0 )); then
    log_ok "${cluster}: PeerAuthentication STRICT ${COUNT}개 적용"
  else
    log_warn "${cluster}: mTLS STRICT 미적용 (04b-istio-mtls.sh 실행 필요)"
  fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 최종 요약
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo
echo "════════════════════════════════════════════════════════════"
echo " 최종 요약"
echo "════════════════════════════════════════════════════════════"
echo -e "  ${GRN}[OK]${NC}   ${OK_COUNT}개"
echo -e "  ${YLW}[WARN]${NC} ${WARN_COUNT}개"
echo -e "  ${RED}[FAIL]${NC} ${FAIL_COUNT}개"
echo

if (( FAIL_COUNT == 0 && WARN_COUNT == 0 )); then
  echo -e "  ${GRN}✓ 인프라 전체 정상${NC}"
elif (( FAIL_COUNT == 0 )); then
  echo -e "  ${YLW}△ WARN ${WARN_COUNT}개 — addon 설치 미완료 항목을 확인하세요${NC}"
  echo -e "  ${DIM}  addons/scripts/ 순서대로 실행 후 재검사 권장${NC}"
else
  echo -e "  ${RED}✗ FAIL ${FAIL_COUNT}개 — 즉시 조치 필요${NC}"
fi

echo
echo "  로그 저장: ${LOG_FILE}"
echo "════════════════════════════════════════════════════════════"

# WARN/FAIL 여부와 관계없이 exit 0 (경고 레벨)
exit 0
