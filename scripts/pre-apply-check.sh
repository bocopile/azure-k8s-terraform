#!/usr/bin/env bash
# ============================================================
# pre-apply-check.sh — tofu apply 전 사전 체크
#
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
BLU='\033[0;34m'
NC='\033[0m'

FAIL=0
WARN=0
AUTO_FIX="${1:-}"

log_ok()   { echo -e "  ${GRN}[OK]${NC}   $*"; }
log_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL+1)); }
log_warn() { echo -e "  ${YLW}[WARN]${NC} $*"; WARN=$((WARN+1)); }
log_info() { echo -e "         $*"; }
section()  { echo; echo -e "${BLU}[ $* ]${NC}"; }

# tfvars에서 값 추출 (줄 시작 '#' 주석 제외, 인라인 주석 허용)
tfvar() {
  grep "^[[:space:]]*${1}[[:space:]]*=" "${TFVARS}" | \
    grep -v '^[[:space:]]*#' | \
    sed 's/.*=[[:space:]]*//' | \
    sed 's/[[:space:]]*#.*//' | \
    tr -d '"' | head -1 | xargs 2>/dev/null || true
}

# tfvars에 키가 존재하고 주석 처리되지 않았는지
tfvar_exists() {
  grep -q "^[[:space:]]*${1}[[:space:]]*=" "${TFVARS}" 2>/dev/null
}

echo "============================================================"
echo " pre-apply-check.sh — $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# ── 설정 읽기 ─────────────────────────────────────────────────
SUBSCRIPTION_ID=$(tfvar subscription_id)
TENANT_ID=$(tfvar tenant_id)
KV_SUFFIX=$(tfvar kv_suffix)
KV_NAME="kv-k8s-${KV_SUFFIX}"
LOCATION="koreacentral"
INGRESS_SPOT=$(tfvar ingress_spot_enabled)
INGRESS_NODE_COUNT=$(tfvar ingress_node_count); INGRESS_NODE_COUNT="${INGRESS_NODE_COUNT:-1}"
SYS_COUNT=$(tfvar system_node_count);           SYS_COUNT="${SYS_COUNT:-1}"

# ──────────────────────────────────────────────────────────────
section "Check 1. Azure CLI 로그인 상태"
# ──────────────────────────────────────────────────────────────
if ! az version &>/dev/null; then
  log_fail "az CLI를 찾을 수 없습니다. Azure CLI를 설치하세요."
else
  CURRENT_SUB=$(az account show --query id -o tsv 2>/dev/null || echo "")
  CURRENT_USER=$(az account show --query user.name -o tsv 2>/dev/null || echo "")
  CURRENT_USER_TYPE=$(az account show --query user.type -o tsv 2>/dev/null || echo "")

  if [[ -z "${CURRENT_SUB}" ]]; then
    log_fail "Azure 로그인이 필요합니다."
    log_info "→ az login"
  elif [[ "${CURRENT_SUB}" != "${SUBSCRIPTION_ID}" ]]; then
    log_fail "로그인 구독(${CURRENT_SUB})이 tfvars 구독(${SUBSCRIPTION_ID})과 다릅니다."
    log_info "→ az account set -s ${SUBSCRIPTION_ID}"
  else
    log_ok "구독: ${SUBSCRIPTION_ID}"
    log_ok "사용자: ${CURRENT_USER} (${CURRENT_USER_TYPE})"
  fi

  # Tenant 일치 여부
  CURRENT_TENANT=$(az account show --query tenantId -o tsv 2>/dev/null || echo "")
  if [[ -n "${TENANT_ID}" && "${CURRENT_TENANT}" != "${TENANT_ID}" ]]; then
    log_fail "로그인 테넌트(${CURRENT_TENANT})가 tfvars tenant_id(${TENANT_ID})와 다릅니다."
  elif [[ -n "${CURRENT_TENANT}" ]]; then
    log_ok "테넌트: ${CURRENT_TENANT}"
  fi
fi

# ──────────────────────────────────────────────────────────────
section "Check 2. terraform.tfvars 필수값 검증"
# ──────────────────────────────────────────────────────────────
PLACEHOLDER_PATTERN="xxxxxxxx|your-|example\.com|<.*>|AAAA\.\.\."

# 2-1. 필수 항목 존재 여부
REQUIRED_VARS=("subscription_id" "tenant_id" "acr_name" "kv_suffix" "jumpbox_ssh_public_key")
for v in "${REQUIRED_VARS[@]}"; do
  if ! tfvar_exists "${v}"; then
    log_fail "${v} 가 terraform.tfvars에 없습니다."
  fi
done

# 2-2. Placeholder 값 체크
check_placeholder() {
  local key="$1"
  local val
  val=$(tfvar "${key}")
  if [[ -z "${val}" ]]; then
    log_fail "${key} 값이 비어 있습니다."
  elif echo "${val}" | grep -qE "${PLACEHOLDER_PATTERN}"; then
    log_fail "${key} 가 placeholder 값입니다: '${val}'"
    log_info "→ 실제 값으로 변경하세요."
  else
    log_ok "${key} = ${val:0:20}$([ ${#val} -gt 20 ] && echo '...' || true)"
  fi
}

check_placeholder "subscription_id"
check_placeholder "tenant_id"
check_placeholder "acr_name"
check_placeholder "kv_suffix"

# 2-3. SSH 공개키 형식 확인 (raw 라인 직접 검사 — 키가 길어 xargs 파싱 불가)
SSH_KEY_LINE=$(grep "^[[:space:]]*jumpbox_ssh_public_key" "${TFVARS}" | grep -v '^[[:space:]]*#' | head -1 || true)
if [[ -z "${SSH_KEY_LINE}" ]]; then
  log_fail "jumpbox_ssh_public_key 가 terraform.tfvars에 없습니다."
elif echo "${SSH_KEY_LINE}" | grep -qE "AAAA\.\.\.|your-public-key|placeholder"; then
  log_fail "jumpbox_ssh_public_key 가 placeholder 값입니다."
elif echo "${SSH_KEY_LINE}" | grep -qE "(ssh-rsa|ssh-ed25519|ecdsa-sha2)"; then
  KEY_PREVIEW=$(echo "${SSH_KEY_LINE}" | grep -oE "(ssh-rsa|ssh-ed25519|ecdsa-sha2) [A-Za-z0-9+/]{20}" | head -1)
  log_ok "jumpbox_ssh_public_key = ${KEY_PREVIEW}..."
else
  log_fail "jumpbox_ssh_public_key 형식이 잘못됐습니다. (ssh-rsa / ssh-ed25519 로 시작해야 함)"
fi

# 2-4. flux_ssh_private_key (설정된 경우 형식 확인)
FLUX_KEY_LINE=$(grep -A1 'flux_ssh_private_key' "${TFVARS}" | grep -v '#' | grep -v 'flux_ssh_private_key' | head -1 | xargs 2>/dev/null || true)
if grep -q '^[[:space:]]*flux_ssh_private_key' "${TFVARS}" 2>/dev/null; then
  if grep -A5 'flux_ssh_private_key' "${TFVARS}" | grep -q 'BEGIN OPENSSH PRIVATE KEY'; then
    log_ok "flux_ssh_private_key 설정됨 (OPENSSH 형식)"
  elif grep -A5 'flux_ssh_private_key' "${TFVARS}" | grep -q 'BEGIN RSA PRIVATE KEY'; then
    log_ok "flux_ssh_private_key 설정됨 (RSA 형식)"
  else
    log_warn "flux_ssh_private_key 값이 설정됐지만 키 형식을 확인할 수 없습니다."
  fi
else
  log_warn "flux_ssh_private_key 미설정 — Flux GitOps 사용 시 필요"
fi

# 2-5. addon_repo_url (설정된 경우 형식 확인)
ADDON_URL=$(tfvar addon_repo_url)
if [[ -z "${ADDON_URL}" ]]; then
  log_warn "addon_repo_url 미설정 — 자동 addon 설치 건너뜀 (수동 설치 필요)"
elif echo "${ADDON_URL}" | grep -qE "${PLACEHOLDER_PATTERN}"; then
  log_fail "addon_repo_url 가 placeholder 값입니다: '${ADDON_URL}'"
elif echo "${ADDON_URL}" | grep -qE "^https?://|^git@|^ssh://"; then
  log_ok "addon_repo_url = ${ADDON_URL}"
else
  log_warn "addon_repo_url 형식이 일반적이지 않습니다: ${ADDON_URL}"
fi

# 2-6. 데이터 서비스 활성화 경고
ENABLE_REDIS=$(tfvar enable_redis);       ENABLE_REDIS="${ENABLE_REDIS:-false}"
ENABLE_MYSQL=$(tfvar enable_mysql);       ENABLE_MYSQL="${ENABLE_MYSQL:-false}"
ENABLE_SB=$(tfvar enable_servicebus);     ENABLE_SB="${ENABLE_SB:-false}"
DS_COST=0
[[ "${ENABLE_REDIS}" == "true" ]]  && DS_COST=$((DS_COST+210))
[[ "${ENABLE_MYSQL}" == "true" ]]  && DS_COST=$((DS_COST+41))
[[ "${ENABLE_SB}" == "true" ]]     && DS_COST=$((DS_COST+667))
if (( DS_COST > 0 )); then
  log_warn "Data Services 활성화 — 추가 비용 +\$${DS_COST}/월 예상"
  [[ "${ENABLE_REDIS}" == "true" ]]  && log_info "  Redis Premium    : +\$210/월"
  [[ "${ENABLE_MYSQL}" == "true" ]]  && log_info "  MySQL Flexible   : +\$41/월"
  [[ "${ENABLE_SB}" == "true" ]]     && log_info "  Service Bus Prem : +\$667/월"
else
  log_ok "Data Services 모두 비활성화 (비용 절감)"
fi

# ──────────────────────────────────────────────────────────────
section "Check 3. 공인 IP vs kv_allowed_ips"
# ──────────────────────────────────────────────────────────────
CURRENT_IP=$(curl -s --max-time 5 ifconfig.me || echo "")
KV_ALLOWED=$(grep '^[[:space:]]*kv_allowed_ips' "${TFVARS}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")

if [[ -z "${CURRENT_IP}" ]]; then
  log_fail "공인 IP 조회 실패 (네트워크 확인)"
elif [[ -z "${KV_ALLOWED}" ]]; then
  log_warn "kv_allowed_ips 가 설정되지 않았습니다. Key Vault 접근이 차단될 수 있습니다."
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

# ──────────────────────────────────────────────────────────────
section "Check 4. Soft-deleted Key Vault 충돌 여부 (${KV_NAME})"
# ──────────────────────────────────────────────────────────────
DELETED_KV=$(az keyvault list-deleted --query "[?name=='${KV_NAME}'].name" -o tsv 2>/dev/null || echo "")
if [[ -z "${DELETED_KV}" ]]; then
  log_ok "${KV_NAME} soft-deleted 없음"
else
  if [[ "${AUTO_FIX}" == "--auto-fix" ]]; then
    log_warn "${KV_NAME} soft-deleted 감지 — purge 시작..."
    if az keyvault purge --name "${KV_NAME}" --location "${LOCATION}" 2>/dev/null; then
      log_ok "${KV_NAME} purge 완료"
    else
      log_fail "${KV_NAME} purge 실패 (purge_protection=true 가능성)"
    fi
  else
    log_fail "${KV_NAME}이 soft-deleted 상태 — tofu apply 시 충돌 발생"
    log_info "→ az keyvault purge --name ${KV_NAME} --location ${LOCATION}"
    log_info "→ 또는: bash scripts/pre-apply-check.sh --auto-fix"
  fi
fi

# ──────────────────────────────────────────────────────────────
section "Check 5. Spot(lowPriorityCores) 쿼터"
# ──────────────────────────────────────────────────────────────
if [[ "${INGRESS_SPOT}" == "true" ]]; then
  SPOT_LIMIT=$(az quota show \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Compute/locations/${LOCATION}" \
    --resource-name lowPriorityCores \
    --query "properties.limit.value" -o tsv 2>/dev/null || echo "0")
  REQUIRED_VCPU=$(( INGRESS_NODE_COUNT * 2 * 2 ))
  if (( SPOT_LIMIT >= REQUIRED_VCPU )); then
    log_ok "lowPriorityCores 한도(${SPOT_LIMIT}) >= 필요(${REQUIRED_VCPU} vCPU)"
  else
    log_fail "lowPriorityCores 한도(${SPOT_LIMIT}) < 필요(${REQUIRED_VCPU} vCPU)"
    log_info "→ terraform.tfvars: ingress_spot_enabled = false"
  fi
else
  log_ok "ingress_spot_enabled = false — Spot 쿼터 체크 생략"
fi

# ──────────────────────────────────────────────────────────────
section "Check 6. standardDSv4Family vCPU 쿼터"
# ──────────────────────────────────────────────────────────────
DSV4_LIMIT=$(az quota show \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Compute/locations/${LOCATION}" \
  --resource-name standardDSv4Family \
  --query "properties.limit.value" -o tsv 2>/dev/null || echo "0")
REQUIRED_DSV4=$(( SYS_COUNT * 3 * 2 + INGRESS_NODE_COUNT * 2 * 2 ))
if (( DSV4_LIMIT >= REQUIRED_DSV4 )); then
  log_ok "standardDSv4Family 한도(${DSV4_LIMIT}) >= 필요(${REQUIRED_DSV4} vCPU)"
else
  log_fail "standardDSv4Family 한도(${DSV4_LIMIT}) < 필요(${REQUIRED_DSV4} vCPU)"
  log_info "→ az quota update 로 한도 증가 필요"
fi

# ──────────────────────────────────────────────────────────────
section "Check 7. tofu 설치 및 Backend 초기화 상태"
# ──────────────────────────────────────────────────────────────
if ! command -v tofu &>/dev/null; then
  log_fail "tofu가 설치되지 않았습니다."
  log_info "→ brew install opentofu"
else
  TOFU_VER=$(tofu version -json 2>/dev/null | grep '"terraform_version"' | sed 's/.*: *"\(.*\)".*/\1/' || tofu version | head -1)
  log_ok "tofu 설치됨: ${TOFU_VER}"
fi

if [[ -f "${ROOT_DIR}/.terraform/terraform.tfstate" ]]; then
  log_ok ".terraform 초기화됨"
else
  log_fail ".terraform 없음 — 먼저 실행: bash scripts/init-backend.sh"
fi

# Backend Storage Account 접근 가능 여부
BACKEND_FILE="${ROOT_DIR}/backend.tf"
SA_NAME=$(grep 'storage_account_name' "${BACKEND_FILE}" | sed 's/.*= *"\(.*\)".*/\1/' | head -1 || true)
RG_NAME=$(grep 'resource_group_name' "${BACKEND_FILE}" | sed 's/.*= *"\(.*\)".*/\1/' | head -1 || true)
if [[ -n "${SA_NAME}" ]]; then
  if az storage account show --name "${SA_NAME}" --resource-group "${RG_NAME}" &>/dev/null; then
    log_ok "Backend Storage Account(${SA_NAME}) 접근 가능"
  else
    log_fail "Backend Storage Account(${SA_NAME}) 접근 불가 — bash scripts/init-backend.sh 실행 필요"
  fi
fi

# ──────────────────────────────────────────────────────────────
# 결과 요약
# ──────────────────────────────────────────────────────────────
echo
echo "============================================================"
echo " 결과 요약"
echo "============================================================"
if (( FAIL == 0 && WARN == 0 )); then
  echo -e " ${GRN}✓ 모든 체크 통과 — tofu apply 진행 가능${NC}"
elif (( FAIL == 0 )); then
  echo -e " ${YLW}△ FAIL 없음, WARN ${WARN}개 — 확인 후 진행${NC}"
else
  echo -e " ${RED}✗ FAIL ${FAIL}개, WARN ${WARN}개 — 위 항목 해결 후 재실행${NC}"
fi
echo "============================================================"

if (( FAIL == 0 )); then
  echo
  echo " 배포 명령어:"
  echo "   tofu plan -out=tfplan 2>&1 | tee tofu-plan-\$(date +%Y%m%d-%H%M%S).log"
  echo "   tofu apply tfplan 2>&1 | tee tofu-apply-\$(date +%Y%m%d-%H%M%S).log"
  exit 0
else
  exit 1
fi
