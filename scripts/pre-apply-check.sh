#!/usr/bin/env bash
# ============================================================
# pre-apply-check.sh — tofu apply 전 사전 체크
#
# 통과 실패 시 tofu apply 진행 불가.
# Usage: bash scripts/pre-apply-check.sh [--auto-fix]
#   --auto-fix: KV purge, kv_allowed_ips 자동 수정 시도
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS="${ROOT_DIR}/terraform.tfvars"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
NC='\033[0m'

FAIL=0
AUTO_FIX="${1:-}"

log_ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL+1)); }
log_warn() { echo -e "${YLW}[WARN]${NC} $*"; }
log_info() { echo -e "       $*"; }

# tfvars에서 값 추출 (줄 시작 '#' 주석 제외, 인라인 주석 허용)
tfvar() {
  grep "^[[:space:]]*${1}[[:space:]]*=" "${TFVARS}" | \
    grep -v '^[[:space:]]*#' | \
    sed 's/.*=[[:space:]]*//' | \
    sed 's/[[:space:]]*#.*//' | \
    tr -d '"' | \
    head -1 | xargs
}

echo "============================================================"
echo " pre-apply-check.sh — $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# ── 설정 읽기 ─────────────────────────────────────────────────
SUBSCRIPTION_ID=$(tfvar subscription_id)
KV_SUFFIX=$(tfvar kv_suffix)
KV_NAME="kv-k8s-${KV_SUFFIX}"
LOCATION="koreacentral"
INGRESS_SPOT=$(tfvar ingress_spot_enabled)
INGRESS_NODE_COUNT=$(tfvar ingress_node_count)
INGRESS_NODE_COUNT="${INGRESS_NODE_COUNT:-1}"
SYS_COUNT=$(tfvar system_node_count)
SYS_COUNT="${SYS_COUNT:-1}"

# ── Check 1: Azure CLI 로그인 ──────────────────────────────────
echo
echo "[ Check 1 ] Azure CLI 로그인 상태"
CURRENT_SUB=$(az account show --query id -o tsv 2>/dev/null || echo "")
if [[ "${CURRENT_SUB}" == "${SUBSCRIPTION_ID}" ]]; then
  log_ok "Subscription: ${SUBSCRIPTION_ID}"
else
  log_fail "로그인된 구독(${CURRENT_SUB})이 tfvars 구독(${SUBSCRIPTION_ID})과 다릅니다."
  log_info "→ az login 또는 az account set -s ${SUBSCRIPTION_ID}"
fi

# ── Check 2: 공인 IP vs kv_allowed_ips ────────────────────────
echo
echo "[ Check 2 ] 공인 IP vs kv_allowed_ips"
CURRENT_IP=$(curl -s --max-time 5 ifconfig.me || echo "")
KV_ALLOWED=$(grep '^[[:space:]]*kv_allowed_ips' "${TFVARS}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")

if [[ -z "${CURRENT_IP}" ]]; then
  log_fail "공인 IP 조회 실패 (네트워크 확인)"
elif [[ "${CURRENT_IP}" == "${KV_ALLOWED}" ]]; then
  log_ok "공인 IP(${CURRENT_IP}) = kv_allowed_ips(${KV_ALLOWED}/32)"
else
  if [[ "${AUTO_FIX}" == "--auto-fix" ]]; then
    sed -i.bak "s|\"${KV_ALLOWED}/32\"|\"${CURRENT_IP}/32\"|" "${TFVARS}"
    log_warn "kv_allowed_ips 자동 수정: ${KV_ALLOWED} → ${CURRENT_IP}"
  else
    log_fail "공인 IP(${CURRENT_IP})가 kv_allowed_ips(${KV_ALLOWED})와 다릅니다."
    log_info "→ terraform.tfvars: kv_allowed_ips = [\"${CURRENT_IP}/32\"]"
    log_info "→ 또는: bash scripts/pre-apply-check.sh --auto-fix"
  fi
fi

# ── Check 3: Soft-deleted Key Vault 충돌 ──────────────────────
echo
echo "[ Check 3 ] Soft-deleted Key Vault 충돌 여부 (${KV_NAME})"
DELETED_KV=$(az keyvault list-deleted --query "[?name=='${KV_NAME}'].name" -o tsv 2>/dev/null || echo "")
if [[ -z "${DELETED_KV}" ]]; then
  log_ok "${KV_NAME} soft-deleted 없음 — 충돌 없음"
else
  if [[ "${AUTO_FIX}" == "--auto-fix" ]]; then
    log_warn "${KV_NAME} soft-deleted 감지 — purge 시작 (수 분 소요)..."
    if az keyvault purge --name "${KV_NAME}" --location "${LOCATION}" 2>/dev/null; then
      log_ok "${KV_NAME} purge 완료"
    else
      log_fail "${KV_NAME} purge 실패 (purge_protection=true 가능성 또는 이미 진행 중)"
    fi
  else
    log_fail "${KV_NAME}이 soft-deleted 상태입니다. tofu apply 시 충돌 발생."
    log_info "→ az keyvault purge --name ${KV_NAME} --location ${LOCATION}"
    log_info "→ 또는: bash scripts/pre-apply-check.sh --auto-fix"
  fi
fi

# ── Check 4: Spot 쿼터 (ingress_spot_enabled = true 시) ───────
echo
echo "[ Check 4 ] Spot(lowPriorityCores) 쿼터"
if [[ "${INGRESS_SPOT}" == "true" ]]; then
  SPOT_LIMIT=$(az quota show \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Compute/locations/${LOCATION}" \
    --resource-name lowPriorityCores \
    --query "properties.limit.value" -o tsv 2>/dev/null || echo "0")
  # D2s_v4 = 2 vCPU, clusters_with_ingress = 2 (mgmt+app1)
  REQUIRED_VCPU=$(( INGRESS_NODE_COUNT * 2 * 2 ))

  if (( SPOT_LIMIT >= REQUIRED_VCPU )); then
    log_ok "lowPriorityCores 한도(${SPOT_LIMIT}) >= 필요(${REQUIRED_VCPU} vCPU)"
  else
    log_fail "lowPriorityCores 한도(${SPOT_LIMIT}) < 필요(${REQUIRED_VCPU} vCPU)"
    log_info "→ terraform.tfvars: ingress_spot_enabled = false"
    log_info "→ 또는 쿼터 증가: az quota update --resource-name lowPriorityCores --value ${REQUIRED_VCPU} ..."
  fi
else
  log_ok "ingress_spot_enabled = false — Spot 쿼터 체크 생략"
fi

# ── Check 5: DSv4 vCPU 쿼터 ──────────────────────────────────
echo
echo "[ Check 5 ] standardDSv4Family vCPU 쿼터"
DSV4_LIMIT=$(az quota show \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Compute/locations/${LOCATION}" \
  --resource-name standardDSv4Family \
  --query "properties.limit.value" -o tsv 2>/dev/null || echo "0")

# system: 3clusters × node_count × 2vCPU, ingress: 2clusters × node_count × 2vCPU
REQUIRED_DSV4=$(( SYS_COUNT * 3 * 2 + INGRESS_NODE_COUNT * 2 * 2 ))

if (( DSV4_LIMIT >= REQUIRED_DSV4 )); then
  log_ok "standardDSv4Family 한도(${DSV4_LIMIT}) >= 필요(${REQUIRED_DSV4} vCPU)"
else
  log_fail "standardDSv4Family 한도(${DSV4_LIMIT}) < 필요(${REQUIRED_DSV4} vCPU)"
  log_info "→ az quota update 로 한도 증가 필요"
fi

# ── Check 6: tofu init 완료 여부 ──────────────────────────────
echo
echo "[ Check 6 ] .terraform 초기화 상태"
if [[ -f "${ROOT_DIR}/.terraform/terraform.tfstate" ]]; then
  log_ok ".terraform 초기화됨"
else
  log_warn ".terraform 없음 — tofu init이 필요합니다"
  log_info "→ tofu init"
  FAIL=$((FAIL+1))
fi

# ── 결과 요약 ─────────────────────────────────────────────────
echo
echo "============================================================"
if (( FAIL == 0 )); then
  echo -e "${GRN} 모든 체크 통과 — tofu apply 진행 가능${NC}"
  echo "============================================================"
  echo
  echo "다음 명령어로 배포하세요:"
  echo "  tofu plan -out=tfplan 2>&1 | tee tofu-plan-\$(date +%Y%m%d-%H%M%S).log"
  echo "  tofu apply tfplan 2>&1 | tee tofu-apply-\$(date +%Y%m%d-%H%M%S).log"
  exit 0
else
  echo -e "${RED} ${FAIL}개 체크 실패 — 위 항목 해결 후 재실행하세요${NC}"
  echo "============================================================"
  exit 1
fi
