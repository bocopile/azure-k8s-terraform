#!/usr/bin/env bash
# ============================================================
# scripts/verify.sh — 인프라 배포 후 전체 레이어 종합 검증
#
# 검증 레이어:
#   L1. Azure 리소스 존재 여부 (Resource Groups, AKS, VNet, DNS 등)
#   L2. 네트워크 (VNet Peering, Private DNS Zone 링크, NSG)
#   L3. AKS 노드 & 시스템 Pod 상태
#   L4. Addon 설치 상태 (cert-manager, Istio, Kiali, Karpenter, ESO 등)
#   L5. 보안 (Istio mTLS, cert-manager ClusterIssuer, RBAC)
#   L6. 모니터링 (Prometheus, Grafana 데이터소스)
#   L7. Backup (Extension 설치, BackupInstance 상태)
#
# Usage:
#   ./scripts/verify.sh [options]
#
# Options:
#   --prefix    <k8s>           리소스 네이밍 prefix (default: k8s)
#   --location  <koreacentral>  Azure region (default: koreacentral)
#   --acr-name  <name>          ACR 이름
#   --kv-suffix <suffix>        Key Vault suffix
#   --only      <L1,L3,L5>     특정 레이어만 실행 (콤마 구분)
#   --skip      <L4,L6>        특정 레이어 건너뜀 (콤마 구분)
#   --no-k8s                   K8s 레이어(L3~L5) 건너뜀 (AKS 접근 불가 환경)
#
# Prerequisites:
#   - az CLI 설치 및 az login 완료
#   - K8s 검증(L3~L5): az aks command invoke 사용 (VPN/jumpbox 불필요)
# ============================================================

set -euo pipefail

# ============================================================
# 기본값 및 인수 파싱
# ============================================================
PREFIX="${PREFIX:-k8s}"
LOCATION="${LOCATION:-koreacentral}"
ACR_NAME=""
KV_SUFFIX=""
SKIP_K8S=false
ONLY_LAYERS=""
SKIP_LAYERS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)   PREFIX="$2";    shift 2 ;;
    --location) LOCATION="$2";  shift 2 ;;
    --acr-name) ACR_NAME="$2";  shift 2 ;;
    --kv-suffix) KV_SUFFIX="$2"; shift 2 ;;
    --no-k8s)   SKIP_K8S=true;  shift ;;
    --only)     ONLY_LAYERS="$2"; shift 2 ;;
    --skip)     SKIP_LAYERS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ============================================================
# 색상 & 카운터
# ============================================================
PASS=0; FAIL=0; WARN=0; SKIP=0

ok()      { printf "  \033[32m✓\033[0m %s\n" "$*";   ((PASS++)) || true; }
fail()    { printf "  \033[31m✗\033[0m %s\n" "$*";   ((FAIL++)) || true; }
warn()    { printf "  \033[33m!\033[0m %s\n" "$*";   ((WARN++)) || true; }
skip_msg(){ printf "  \033[36m-\033[0m %s\n" "$*";   ((SKIP++)) || true; }
section() { echo ""; echo "▶ $*"; }
log()     { echo "[$(date '+%H:%M:%S')] $*"; }

# 레이어 활성화 여부 판단
layer_enabled() {
  local layer="$1"
  [[ -n "${ONLY_LAYERS}" ]] && [[ "${ONLY_LAYERS}" != *"${layer}"* ]] && return 1
  [[ "${SKIP_LAYERS}" == *"${layer}"* ]] && return 1
  if [[ "${SKIP_K8S}" == "true" ]] && [[ "${layer}" =~ ^L[345]$ ]]; then return 1; fi
  return 0
}

# ============================================================
# 파생 이름 (locals.tf 규칙과 동일)
# ============================================================
RG_COMMON="rg-${PREFIX}-common"
RG_MGMT="rg-${PREFIX}-mgmt"
PREFIX_NODASH="${PREFIX//-/}"
KV_SUFFIX_LOWER="$(echo "${KV_SUFFIX:-}" | tr 'A-Z' 'a-z')"

# ============================================================
# az aks command invoke 래퍼 — VPN 없이 kubectl 실행
# ============================================================
aks_invoke() {
  local rg="$1" aks="$2" cmd="$3"
  az aks command invoke \
    --resource-group "${rg}" \
    --name "${aks}" \
    --command "${cmd}" \
    --query "logs" \
    --output tsv 2>/dev/null || echo ""
}

# ============================================================
# 전제 조건 확인
# ============================================================
if ! command -v az &>/dev/null; then
  echo "ERROR: az CLI가 설치되지 않았습니다." >&2; exit 1
fi
if ! az account show --output none 2>/dev/null; then
  echo "ERROR: az login이 필요합니다." >&2; exit 1
fi

SUBSCRIPTION=$(az account show --query "id" -o tsv 2>/dev/null)
ACCOUNT_NAME=$(az account show --query "name" -o tsv 2>/dev/null)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Azure K8s 인프라 종합 검증 (verify.sh)               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
log "Subscription : ${ACCOUNT_NAME} (${SUBSCRIPTION})"
log "Prefix       : ${PREFIX}"
log "Location     : ${LOCATION}"
log "RG Common    : ${RG_COMMON}"
[[ -n "${ONLY_LAYERS}" ]] && log "Only layers  : ${ONLY_LAYERS}"
[[ -n "${SKIP_LAYERS}" ]] && log "Skip layers  : ${SKIP_LAYERS}"
[[ "${SKIP_K8S}" == "true" ]] && log "K8s checks   : 건너뜀 (--no-k8s)"

# ============================================================
# L1: Azure 리소스 존재 여부
# ============================================================
if layer_enabled "L1"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "L1. Azure 리소스 존재 여부"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  section "Resource Groups"
  for rg in "${RG_COMMON}" "rg-${PREFIX}-mgmt" "rg-${PREFIX}-app1" "rg-${PREFIX}-app2"; do
    if az group show -n "${rg}" --output none 2>/dev/null; then
      ok "RG: ${rg}"
    else
      fail "RG: ${rg} (없음)"
    fi
  done

  section "AKS Clusters"
  for cluster in mgmt app1 app2; do
    rg="rg-${PREFIX}-${cluster}"
    aks="aks-${cluster}"
    if az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then
      state=$(az aks show -g "${rg}" -n "${aks}" --query "provisioningState" -o tsv 2>/dev/null)
      k8s_ver=$(az aks show -g "${rg}" -n "${aks}" --query "currentKubernetesVersion" -o tsv 2>/dev/null)
      [[ "${state}" == "Succeeded" ]] \
        && ok "AKS: ${aks} (${state}, k8s ${k8s_ver})" \
        || warn "AKS: ${aks} (${state})"
    else
      fail "AKS: ${aks} (없음)"
    fi
  done

  section "Monitoring"
  az monitor log-analytics workspace show -g "${RG_COMMON}" -n "law-${PREFIX}" --output none 2>/dev/null \
    && ok "Log Analytics: law-${PREFIX}" || fail "Log Analytics: law-${PREFIX} (없음)"
  az resource show -g "${RG_COMMON}" -n "mon-${PREFIX}" \
    --resource-type "microsoft.monitor/accounts" --output none 2>/dev/null \
    && ok "Monitor Workspace: mon-${PREFIX}" || fail "Monitor Workspace: mon-${PREFIX} (없음)"
  az grafana show -g "${RG_COMMON}" -n "grafana-${PREFIX}" --output none 2>/dev/null \
    && ok "Managed Grafana: grafana-${PREFIX}" || warn "Managed Grafana: grafana-${PREFIX} (없음 또는 비활성화)"

  section "Key Vault & ACR"
  if [[ -n "${KV_SUFFIX}" ]]; then
    kv_name="kv-${PREFIX}-${KV_SUFFIX}"
    az keyvault show -n "${kv_name}" -g "${RG_COMMON}" --output none 2>/dev/null \
      && ok "Key Vault: ${kv_name}" || fail "Key Vault: ${kv_name} (없음)"
  else
    warn "Key Vault: --kv-suffix 미설정으로 검증 건너뜀"
  fi
  if [[ -n "${ACR_NAME}" ]]; then
    az acr show -n "${ACR_NAME}" -g "${RG_COMMON}" --output none 2>/dev/null \
      && ok "ACR: ${ACR_NAME}" || fail "ACR: ${ACR_NAME} (없음)"
  else
    warn "ACR: --acr-name 미설정으로 검증 건너뜀"
  fi

  section "Jumpbox & Bastion"
  az vm show -g "${RG_MGMT}" -n "vm-jumpbox" --output none 2>/dev/null \
    && ok "VM: vm-jumpbox" || fail "VM: vm-jumpbox (없음)"
  az network bastion show -g "${RG_MGMT}" -n "bastion-${PREFIX}" --output none 2>/dev/null \
    && ok "Bastion: bastion-${PREFIX}" || fail "Bastion: bastion-${PREFIX} (없음)"

  section "Backup"
  az dataprotection backup-vault show -g "${RG_COMMON}" --vault-name "bv-${PREFIX}" --output none 2>/dev/null \
    && ok "Backup Vault: bv-${PREFIX}" || fail "Backup Vault: bv-${PREFIX} (없음)"
fi

# ============================================================
# L2: 네트워크
# ============================================================
if layer_enabled "L2"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "L2. 네트워크 연결성"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  section "VNet Peering 상태"
  for pair in "mgmt:app1" "mgmt:app2" "app1:app2"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    peering_name="peer-${src}-to-${dst}"
    state=$(az network vnet peering show \
      -g "${RG_COMMON}" --vnet-name "vnet-${src}" -n "${peering_name}" \
      --query "peeringState" -o tsv 2>/dev/null || echo "NotFound")
    [[ "${state}" == "Connected" ]] \
      && ok "VNet Peering: ${src} ↔ ${dst} (Connected)" \
      || fail "VNet Peering: ${src} ↔ ${dst} (${state})"
  done

  section "Private DNS Zone — AKS"
  dns_zone="privatelink.${LOCATION}.azmk8s.io"
  az network private-dns zone show -g "${RG_COMMON}" -n "${dns_zone}" --output none 2>/dev/null \
    && ok "AKS Private DNS Zone: ${dns_zone}" \
    || fail "AKS Private DNS Zone: ${dns_zone} (없음)"

  # AKS Private DNS Zone → 각 VNet 링크 확인
  for vnet in mgmt app1 app2; do
    link_count=$(az network private-dns link vnet list \
      -g "${RG_COMMON}" --zone-name "${dns_zone}" \
      --query "[?contains(name, '${vnet}')].provisioningState" -o tsv 2>/dev/null | wc -l | tr -d ' ')
    [[ "${link_count}" -gt 0 ]] \
      && ok "  DNS Zone Link: ${dns_zone} → vnet-${vnet}" \
      || warn "  DNS Zone Link: ${dns_zone} → vnet-${vnet} (없음)"
  done

  section "Private DNS Zone — Key Vault"
  az network private-dns zone show -g "${RG_COMMON}" -n "privatelink.vaultcore.azure.net" --output none 2>/dev/null \
    && ok "KV Private DNS Zone: privatelink.vaultcore.azure.net" \
    || fail "KV Private DNS Zone: privatelink.vaultcore.azure.net (없음)"

  section "NSG 존재 여부"
  for nsg in "nsg-aks-mgmt" "nsg-aks-app1" "nsg-aks-app2" "nsg-bastion" "nsg-jumpbox"; do
    az network nsg show -g "${RG_COMMON}" -n "${nsg}" --output none 2>/dev/null \
      && ok "NSG: ${nsg}" || fail "NSG: ${nsg} (없음)"
  done

  section "Backup Instance 상태"
  instances=$(az dataprotection backup-instance list \
    -g "${RG_COMMON}" --vault-name "bv-${PREFIX}" \
    --query "[].{name:name,state:properties.protectionStatus.status}" -o tsv 2>/dev/null || echo "")
  if [[ -z "${instances}" ]]; then
    warn "Backup Instance: 없음 (tofu apply 또는 extension 설치 확인 필요)"
  else
    while IFS=$'\t' read -r inst_name inst_state; do
      [[ "${inst_state}" == "ProtectionConfigured" ]] \
        && ok "Backup Instance: ${inst_name} (${inst_state})" \
        || warn "Backup Instance: ${inst_name} (${inst_state})"
    done <<< "${instances}"
  fi
fi

# ============================================================
# L3: AKS 노드 & 시스템 Pod 상태
# ============================================================
if layer_enabled "L3"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "L3. AKS 노드 & 시스템 Pod 상태"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  for cluster in mgmt app1 app2; do
    rg="rg-${PREFIX}-${cluster}"
    aks="aks-${cluster}"

    # 클러스터 존재 여부 확인
    if ! az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then
      warn "L3 건너뜀: ${aks} 없음"
      continue
    fi

    section "노드 상태 — ${aks}"

    # 노드 Ready 여부
    node_output=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,READY:.status.conditions[-1].status,POOL:.metadata.labels['agentpool'] --no-headers")
    if [[ -z "${node_output}" ]]; then
      warn "노드 정보 조회 실패 (invoke timeout 또는 접근 권한 문제)"
    else
      not_ready=0
      while IFS= read -r line; do
        if [[ -z "${line}" ]]; then continue; fi
        node_name=$(echo "${line}" | awk '{print $1}')
        status=$(echo "${line}" | awk '{print $2}')
        ready=$(echo "${line}" | awk '{print $3}')
        pool=$(echo "${line}" | awk '{print $4}')
        if [[ "${status}" == "Ready" && "${ready}" == "True" ]]; then
          ok "  Node: ${node_name} [${pool}] (Ready)"
        else
          fail "  Node: ${node_name} [${pool}] (${status}=${ready})"
          ((not_ready++)) || true
        fi
      done <<< "${node_output}"
    fi

    section "시스템 Pod 상태 — ${aks} (kube-system)"
    pod_output=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get pods -n kube-system --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | head -10")
    if [[ -z "${pod_output}" ]]; then
      ok "kube-system: 비정상 Pod 없음"
    else
      fail "kube-system 비정상 Pod 발견:"
      while IFS= read -r line; do
        [[ -n "${line}" ]] && fail "  ${line}"
      done <<< "${pod_output}"
    fi
  done
fi

# ============================================================
# L4: Addon 설치 상태
# ============================================================
if layer_enabled "L4"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "L4. Addon 설치 상태"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # ---- cert-manager (mgmt only) ----
  section "cert-manager (mgmt)"
  rg="rg-${PREFIX}-mgmt"; aks="aks-mgmt"
  if az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then
    cm_pods=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get pods -n cert-manager -l app.kubernetes.io/name=cert-manager --no-headers 2>/dev/null | grep -c Running || echo 0")
    cm_pods="${cm_pods//[^0-9]/}"
    [[ "${cm_pods:-0}" -gt 0 ]] \
      && ok "cert-manager: ${cm_pods} pod(s) Running" \
      || fail "cert-manager: Pod 없음 또는 미설치 (01-cert-manager.sh 실행 필요)"

    ci_output=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get clusterissuers -o name 2>/dev/null || echo ''")
    if echo "${ci_output}" | grep -q "clusterissuer"; then
      ci_count=$(echo "${ci_output}" | grep -c "clusterissuer" || echo 0)
      ok "ClusterIssuer: ${ci_count}개 존재"
    else
      warn "ClusterIssuer: 없음 (01-cert-manager.sh ClusterIssuer 생성 확인)"
    fi
  fi

  # ---- Istio (mgmt, app1) ----
  section "Istio (mgmt, app1)"
  for cluster in mgmt app1; do
    rg="rg-${PREFIX}-${cluster}"; aks="aks-${cluster}"
    if ! az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then continue; fi

    # AKS Istio addon 활성화 여부
    istio_profile=$(az aks show -g "${rg}" -n "${aks}" \
      --query "serviceMeshProfile.mode" -o tsv 2>/dev/null || echo "Disabled")
    if [[ "${istio_profile}" == "Istio" ]]; then
      ok "Istio: ${aks} 활성화됨 (AKS Mesh mode=Istio)"
    else
      fail "Istio: ${aks} 비활성화 (mode=${istio_profile}, 04-istio.sh 실행 필요)"
    fi

    # istiod pod
    istiod_pods=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get pods -n aks-istio-system -l app=istiod --no-headers 2>/dev/null | grep -c Running || echo 0")
    istiod_pods="${istiod_pods//[^0-9]/}"
    [[ "${istiod_pods:-0}" -gt 0 ]] \
      && ok "istiod: ${istiod_pods} pod(s) Running on ${aks}" \
      || warn "istiod: 실행 중인 Pod 없음 (${aks})"

    # Ingress Gateway pod (ingress 노드풀 배포 대상)
    igw_pods=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get pods -n aks-istio-ingress -l app=aks-istio-ingressgateway-external --no-headers 2>/dev/null | grep -c Running || echo 0")
    igw_pods="${igw_pods//[^0-9]/}"
    [[ "${igw_pods:-0}" -gt 0 ]] \
      && ok "Istio Ingress Gateway: ${igw_pods} pod(s) Running on ${aks}" \
      || warn "Istio Ingress Gateway: 실행 중인 Pod 없음 (${aks})"
  done

  # ---- Kiali (mgmt only) ----
  section "Kiali (mgmt)"
  rg="rg-${PREFIX}-mgmt"; aks="aks-mgmt"
  if az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then
    kiali_pods=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get pods -n kiali-operator -l app=kiali-operator --no-headers 2>/dev/null | grep -c Running || echo 0")
    kiali_pods="${kiali_pods//[^0-9]/}"
    [[ "${kiali_pods:-0}" -gt 0 ]] \
      && ok "Kiali Operator: Running" \
      || warn "Kiali Operator: 없음 (07-kiali.sh 실행 필요)"

    kiali_cr=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get kiali -n istio-system 2>/dev/null | grep -c kiali || echo 0")
    kiali_cr="${kiali_cr//[^0-9]/}"
    [[ "${kiali_cr:-0}" -gt 0 ]] \
      && ok "Kiali CR: 존재" \
      || warn "Kiali CR: 없음 (07-kiali.sh Kiali CR 생성 확인)"
  fi

  # ---- Karpenter NodePool (전체) ----
  section "Karpenter / NAP NodePool"
  for cluster in mgmt app1 app2; do
    rg="rg-${PREFIX}-${cluster}"; aks="aks-${cluster}"
    if ! az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then continue; fi

    # NAP mode 확인
    nap_mode=$(az aks show -g "${rg}" -n "${aks}" \
      --query "nodeProvisioningProfile.mode" -o tsv 2>/dev/null || echo "Manual")
    [[ "${nap_mode}" == "Auto" ]] \
      && ok "NAP/Karpenter: ${aks} mode=Auto" \
      || warn "NAP/Karpenter: ${aks} mode=${nap_mode}"

    nodepool_count=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get nodepools.karpenter.sh 2>/dev/null | grep -vc NAME || echo 0")
    nodepool_count="${nodepool_count//[^0-9]/}"
    [[ "${nodepool_count:-0}" -gt 0 ]] \
      && ok "Karpenter NodePool: ${nodepool_count}개 (${aks})" \
      || warn "Karpenter NodePool: 없음 (08-karpenter-nodepool.sh 실행 필요)"
  done

  # ---- External Secrets Operator (전체) ----
  section "External Secrets Operator"
  for cluster in mgmt app1 app2; do
    rg="rg-${PREFIX}-${cluster}"; aks="aks-${cluster}"
    if ! az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then continue; fi
    eso_pods=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get pods -n external-secrets -l app.kubernetes.io/name=external-secrets --no-headers 2>/dev/null | grep -c Running || echo 0")
    eso_pods="${eso_pods//[^0-9]/}"
    [[ "${eso_pods:-0}" -gt 0 ]] \
      && ok "ESO: Running on ${aks}" \
      || warn "ESO: 없음 (02-external-secrets.sh 실행 필요)"
  done

  # ---- Flux Extension (전체) ----
  section "Flux v2 Extension"
  for cluster in mgmt app1 app2; do
    rg="rg-${PREFIX}-${cluster}"; aks="aks-${cluster}"
    if ! az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then continue; fi
    flux_state=$(az k8s-extension show \
      -g "${rg}" -c "aks-${cluster}" \
      --cluster-type managedClusters -n flux \
      --query "installState" -o tsv 2>/dev/null || echo "NotInstalled")
    [[ "${flux_state}" == "Installed" ]] \
      && ok "Flux: ${aks} (${flux_state})" \
      || warn "Flux Extension: ${aks} (${flux_state})"
  done
fi

# ============================================================
# L5: 보안 검증 (Istio mTLS, RBAC)
# ============================================================
if layer_enabled "L5"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "L5. 보안"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  section "Istio mTLS STRICT (mgmt, app1)"
  for cluster in mgmt app1; do
    rg="rg-${PREFIX}-${cluster}"; aks="aks-${cluster}"
    if ! az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then continue; fi

    pa_output=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get peerauthentication -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.mtls.mode}{\"\\n\"}{end}' 2>/dev/null || echo ''")
    if echo "${pa_output}" | grep -q "STRICT"; then
      strict_count=$(echo "${pa_output}" | grep -c "STRICT" || echo 0)
      ok "PeerAuthentication STRICT: ${strict_count}개 (${aks})"
    else
      warn "PeerAuthentication STRICT: 없음 (${aks}) — 04b-istio-mtls.sh 실행 필요"
    fi

    dr_output=$(aks_invoke "${rg}" "${aks}" \
      "kubectl get destinationrule -A --no-headers 2>/dev/null | grep -c ISTIO_MUTUAL || echo 0")
    dr_count="${dr_output//[^0-9]/}"
    [[ "${dr_count:-0}" -gt 0 ]] \
      && ok "DestinationRule ISTIO_MUTUAL: ${dr_count}개 (${aks})" \
      || warn "DestinationRule ISTIO_MUTUAL: 없음 (${aks})"
  done

  section "Key Vault RBAC"
  if [[ -n "${KV_SUFFIX}" ]]; then
    kv_name="kv-${PREFIX}-${KV_SUFFIX}"
    kv_id=$(az keyvault show -n "${kv_name}" -g "${RG_COMMON}" \
      --query "id" -o tsv 2>/dev/null || echo "")
    if [[ -n "${kv_id}" ]]; then
      kv_admin_count=$(az role assignment list --scope "${kv_id}" \
        --query "[?roleDefinitionName=='Key Vault Administrator'].principalId" -o tsv 2>/dev/null | wc -l | tr -d ' ')
      [[ "${kv_admin_count:-0}" -gt 0 ]] \
        && ok "Key Vault Administrator: ${kv_admin_count}명 할당됨" \
        || warn "Key Vault Administrator: 없음"
    fi
  fi

  section "Grafana Admin RBAC"
  grafana_id=$(az grafana show -g "${RG_COMMON}" -n "grafana-${PREFIX}" \
    --query "id" -o tsv 2>/dev/null || echo "")
  if [[ -n "${grafana_id}" ]]; then
    grafana_admin_count=$(az role assignment list --scope "${grafana_id}" \
      --query "[?roleDefinitionName=='Grafana Admin'].principalId" -o tsv 2>/dev/null | wc -l | tr -d ' ')
    [[ "${grafana_admin_count:-0}" -gt 0 ]] \
      && ok "Grafana Admin 역할: ${grafana_admin_count}명 할당됨" \
      || warn "Grafana Admin 역할: 없음 (대시보드 접근 불가)"
  fi
fi

# ============================================================
# L6: 모니터링
# ============================================================
if layer_enabled "L6"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "L6. 모니터링"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  section "Azure Monitor Metrics — AKS 연동"
  for cluster in mgmt app1 app2; do
    rg="rg-${PREFIX}-${cluster}"; aks="aks-${cluster}"
    if ! az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then continue; fi
    prometheus_enabled=$(az aks show -g "${rg}" -n "${aks}" \
      --query "azureMonitorProfile.metrics.enabled" -o tsv 2>/dev/null || echo "false")
    [[ "${prometheus_enabled}" == "true" ]] \
      && ok "Managed Prometheus: ${aks} (enabled)" \
      || fail "Managed Prometheus: ${aks} (disabled)"
  done

  section "Azure Managed Grafana"
  grafana_state=$(az grafana show -g "${RG_COMMON}" -n "grafana-${PREFIX}" \
    --query "properties.provisioningState" -o tsv 2>/dev/null || echo "NotFound")
  if [[ "${grafana_state}" == "Succeeded" ]]; then
    grafana_url=$(az grafana show -g "${RG_COMMON}" -n "grafana-${PREFIX}" \
      --query "properties.endpoint" -o tsv 2>/dev/null || echo "")
    ok "Grafana: ${grafana_state} — ${grafana_url}"
  else
    warn "Grafana: ${grafana_state}"
  fi

  section "Container Insights (OMS Agent)"
  for cluster in mgmt app1 app2; do
    rg="rg-${PREFIX}-${cluster}"; aks="aks-${cluster}"
    if ! az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then continue; fi
    oms=$(az aks show -g "${rg}" -n "${aks}" \
      --query "addonProfiles.omsagent.enabled" -o tsv 2>/dev/null || echo "false")
    [[ "${oms}" == "true" ]] \
      && ok "Container Insights (OMS): ${aks} (enabled)" \
      || warn "Container Insights: ${aks} (disabled)"
  done
fi

# ============================================================
# L7: Backup
# ============================================================
if layer_enabled "L7"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "L7. Backup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  section "AKS Backup Extension (전체 클러스터)"
  for cluster in mgmt app1 app2; do
    rg="rg-${PREFIX}-${cluster}"; aks="aks-${cluster}"
    if ! az aks show -g "${rg}" -n "${aks}" --output none 2>/dev/null; then continue; fi
    ext_state=$(az k8s-extension show \
      -g "${rg}" -c "${aks}" \
      --cluster-type managedClusters -n azure-aks-backup \
      --query "installState" -o tsv 2>/dev/null || echo "NotInstalled")
    [[ "${ext_state}" == "Installed" ]] \
      && ok "Backup Extension: ${aks} (${ext_state})" \
      || warn "Backup Extension: ${aks} (${ext_state}) — 09-backup-extension.sh 또는 tofu apply 확인"
  done

  section "Backup Instances"
  if az dataprotection backup-vault show -g "${RG_COMMON}" --vault-name "bv-${PREFIX}" --output none 2>/dev/null; then
    instances=$(az dataprotection backup-instance list \
      -g "${RG_COMMON}" --vault-name "bv-${PREFIX}" \
      --query "[].{name:name,status:properties.protectionStatus.status}" \
      -o tsv 2>/dev/null || echo "")
    if [[ -z "${instances}" ]]; then
      warn "Backup Instances: 없음"
    else
      while IFS=$'\t' read -r name status; do
        [[ "${status}" == "ProtectionConfigured" ]] \
          && ok "Backup Instance: ${name} (${status})" \
          || warn "Backup Instance: ${name} (${status})"
      done <<< "${instances}"
    fi
  else
    fail "Backup Vault: bv-${PREFIX} 없음"
  fi
fi

# ============================================================
# 최종 결과 요약
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      검증 결과 요약                          ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  \033[32mPASS\033[0m : %-3d   \033[31mFAIL\033[0m : %-3d   \033[33mWARN\033[0m : %-3d   건너뜀 : %-3d      ║\n" \
  "${PASS}" "${FAIL}" "${WARN}" "${SKIP}"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  echo "  ✗ ${FAIL}개 항목 실패 — tofu apply 완료 여부 및 위 오류를 확인하세요."
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo "  ! ${WARN}개 경고 — Addon 설치 미완료 또는 선택적 기능일 수 있습니다."
  exit 0
else
  echo "  ✓ 모든 검증 항목 통과"
  exit 0
fi
