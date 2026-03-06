#!/usr/bin/env bash
# ============================================================
# scripts/preflight.sh — tofu apply 전 사전 검증 (Pre-flight Check)
#
# 검증 단계:
#   P1. 도구 확인      — tofu(≥1.11), az CLI, git
#   P2. 변수 검증      — terraform.tfvars 필수 항목, 형식, 값 범위
#   P3. Azure 인증     — az login 상태, 구독 일치
#   P4. 권한 검증      — Contributor + User Access Administrator
#   P5. State Backend  — rg-tfstate / Storage Account / Container 접근
#   P6. 공급자 등록    — 필수 Resource Provider 등록 여부
#   P7. 리소스 충돌    — Soft-deleted KV, 기존 RG 충돌 감지
#   P8. 쿼터 확인      — 리전 vCPU 가용 용량
#   P9. Addon 사전조건 — addon_repo_url / addon_env 필수 항목
#
# 모든 항목 통과 시 배포 순서(설치 순서 그래프)를 출력합니다.
#
# Usage:
#   chmod +x scripts/preflight.sh
#   ./scripts/preflight.sh [--tfvars terraform.tfvars] [--skip <P6,P8>] [--fix-providers]
#
# Options:
#   --tfvars        tfvars 파일 경로 (default: terraform.tfvars)
#   --skip          건너뜀 단계 목록 (콤마 구분, 예: P6,P8)
#   --fix-providers 미등록 Provider 자동 등록 (P6 실패 시)
# ============================================================

set -euo pipefail

# ============================================================
# 인수 파싱
# ============================================================
TFVARS="terraform.tfvars"
SKIP_STEPS=""
FIX_PROVIDERS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars)        TFVARS="$2";       shift 2 ;;
    --skip)          SKIP_STEPS="$2";   shift 2 ;;
    --fix-providers) FIX_PROVIDERS=true; shift ;;
    --help|-h)
      sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ============================================================
# 색상 & 카운터
# ============================================================
PASS=0; FAIL=0; WARN=0

ok()      { printf "  \033[32m[PASS]\033[0m %s\n" "$*"; ((PASS++)) || true; }
fail()    { printf "  \033[31m[FAIL]\033[0m %s\n" "$*"; ((FAIL++)) || true; }
warn()    { printf "  \033[33m[WARN]\033[0m %s\n" "$*"; ((WARN++)) || true; }
info()    { printf "  \033[36m[INFO]\033[0m %s\n" "$*"; }
section() { echo ""; printf "\033[1m▶ %s\033[0m\n" "$*"; }
step_header() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "\033[1;34m  %s\033[0m\n" "$*"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

step_enabled() {
  [[ "${SKIP_STEPS}" != *"$1"* ]]
}

# ============================================================
# terraform.tfvars 파서
# 단순 string/bool/number 값 추출 (HCL 부분 파싱)
# ============================================================
TFVARS_PATH=""

find_tfvars() {
  local candidates=(
    "${TFVARS}"
    "$(dirname "$0")/../${TFVARS}"
    "$(pwd)/${TFVARS}"
  )
  for f in "${candidates[@]}"; do
    if [[ -f "${f}" ]]; then
      TFVARS_PATH="$(realpath "${f}")"
      return 0
    fi
  done
  return 1
}

# tfvars에서 단순 문자열 값 추출 (key = "value" 형식)
tfvar_str() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "${TFVARS_PATH}" 2>/dev/null \
    | head -1 \
    | sed -E 's/^[^=]+=\s*"?([^"#]*)"?.*/\1/' \
    | tr -d ' \t'
}

# tfvars에서 키 존재 여부만 확인 (주석 제외)
tfvar_exists() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "${TFVARS_PATH}" &>/dev/null
}

# addon_env 내 특정 키 존재 및 값 비어있지 않음 확인
addon_env_key() {
  local key="$1"
  grep -A100 "^[[:space:]]*addon_env" "${TFVARS_PATH}" 2>/dev/null \
    | grep -E "^\s*${key}\s*=" \
    | grep -v '^\s*#' \
    | grep -v '=""' &>/dev/null
}

# ============================================================
# 배너
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Pre-flight Check — tofu apply 사전 검증              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ============================================================
# P1. 도구 확인
# ============================================================
step_header "P1. 도구 확인 (tofu, az, git)"

# OpenTofu
if command -v tofu &>/dev/null; then
  tofu_ver=$(tofu version -json 2>/dev/null | grep '"terraform_version"' | sed 's/.*: *"\(.*\)".*/\1/' || tofu version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  major=$(echo "${tofu_ver}" | cut -d. -f1)
  minor=$(echo "${tofu_ver}" | cut -d. -f2)
  if [[ "${major}" -ge 1 && "${minor}" -ge 11 ]] 2>/dev/null || [[ "${major}" -gt 1 ]] 2>/dev/null; then
    ok "OpenTofu: v${tofu_ver} (요구: ≥ 1.11)"
  else
    fail "OpenTofu: v${tofu_ver} — 1.11 이상 필요 (https://opentofu.org/docs/intro/install/)"
  fi
else
  fail "OpenTofu: 미설치 (https://opentofu.org/docs/intro/install/)"
fi

# Azure CLI
if command -v az &>/dev/null; then
  az_ver=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "unknown")
  ok "Azure CLI: v${az_ver}"
else
  fail "Azure CLI: 미설치 (https://learn.microsoft.com/ko-kr/cli/azure/install-azure-cli)"
fi

# git (addon_repo_url 클론에 필요)
if command -v git &>/dev/null; then
  git_ver=$(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  ok "git: v${git_ver}"
else
  warn "git: 미설치 (addon_repo_url 미사용 시 무방)"
fi

# ============================================================
# P2. 변수 검증 (terraform.tfvars)
# ============================================================
step_header "P2. 변수 검증 (terraform.tfvars)"

# tfvars 파일 탐색
if find_tfvars; then
  ok "terraform.tfvars: ${TFVARS_PATH}"
else
  fail "terraform.tfvars 파일을 찾을 수 없습니다 (경로: ${TFVARS})"
  fail "terraform.tfvars.example을 복사하여 실제 값을 입력하세요:"
  fail "  cp terraform.tfvars.example terraform.tfvars"
  echo ""
  echo "  Pre-flight를 계속 진행할 수 없습니다."
  exit 1
fi

section "필수 변수"

# subscription_id
SUB_ID=$(tfvar_str "subscription_id")
if [[ -n "${SUB_ID}" ]] && echo "${SUB_ID}" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  ok "subscription_id: ${SUB_ID}"
else
  fail "subscription_id: 미설정 또는 UUID 형식 아님 (예: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)"
fi

# tenant_id
TENANT_ID=$(tfvar_str "tenant_id")
if [[ -n "${TENANT_ID}" ]] && echo "${TENANT_ID}" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  ok "tenant_id: ${TENANT_ID}"
else
  fail "tenant_id: 미설정 또는 UUID 형식 아님"
fi

# acr_name
ACR_NAME=$(tfvar_str "acr_name")
if [[ -n "${ACR_NAME}" ]] && echo "${ACR_NAME}" | grep -qE '^[a-zA-Z0-9]{5,50}$'; then
  ok "acr_name: ${ACR_NAME} (형식 OK)"
else
  fail "acr_name: 미설정 또는 형식 오류 — 5~50자 영숫자만 허용 (현재: '${ACR_NAME}')"
fi

# kv_suffix
KV_SUFFIX=$(tfvar_str "kv_suffix")
if [[ -n "${KV_SUFFIX}" ]] && echo "${KV_SUFFIX}" | grep -qE '^[a-zA-Z0-9]{3,8}$'; then
  ok "kv_suffix: ${KV_SUFFIX} (형식 OK)"
else
  fail "kv_suffix: 미설정 또는 형식 오류 — 3~8자 영숫자만 허용 (현재: '${KV_SUFFIX}')"
fi

# jumpbox_ssh_public_key
SSH_KEY=$(tfvar_str "jumpbox_ssh_public_key")
if [[ -n "${SSH_KEY}" ]] && echo "${SSH_KEY}" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+) [A-Za-z0-9+/]'; then
  key_type=$(echo "${SSH_KEY}" | awk '{print $1}')
  ok "jumpbox_ssh_public_key: ${key_type} (...)"
else
  fail "jumpbox_ssh_public_key: 미설정 또는 형식 오류 — ssh-rsa 또는 ssh-ed25519 공개키"
  info "  생성 방법: ssh-keygen -t ed25519 -f ~/.ssh/id_jumpbox -C jumpbox"
  info "  공개키 확인: cat ~/.ssh/id_jumpbox.pub"
fi

section "선택 변수 형식 검증"

# PREFIX (default: k8s)
PREFIX=$(tfvar_str "prefix")
PREFIX="${PREFIX:-k8s}"
if echo "${PREFIX}" | grep -qE '^[a-z0-9][a-z0-9-]{0,18}[a-z0-9]$|^[a-z0-9]$'; then
  ok "prefix: '${PREFIX}' (형식 OK)"
else
  fail "prefix: '${PREFIX}' — 소문자 영숫자 및 하이픈만 허용, 양 끝은 영숫자"
fi

# LOCATION (default: koreacentral)
LOCATION=$(tfvar_str "location")
LOCATION="${LOCATION:-koreacentral}"
ok "location: ${LOCATION}"

# aks_sku_tier
AKS_SKU=$(tfvar_str "aks_sku_tier")
AKS_SKU="${AKS_SKU:-Standard}"
if [[ "${AKS_SKU}" == "Free" || "${AKS_SKU}" == "Standard" ]]; then
  ok "aks_sku_tier: ${AKS_SKU}"
else
  fail "aks_sku_tier: '${AKS_SKU}' — Free 또는 Standard만 허용"
fi

# vm_size_system / vm_size_ingress (기본값 존재)
VM_SYSTEM=$(tfvar_str "vm_size_system"); VM_SYSTEM="${VM_SYSTEM:-Standard_D2s_v4}"
VM_INGRESS=$(tfvar_str "vm_size_ingress"); VM_INGRESS="${VM_INGRESS:-Standard_D2s_v4}"
VM_JUMPBOX=$(tfvar_str "vm_size_jumpbox"); VM_JUMPBOX="${VM_JUMPBOX:-Standard_B2s}"
ok "vm_size_system: ${VM_SYSTEM}"
ok "vm_size_ingress: ${VM_INGRESS}"
ok "vm_size_jumpbox: ${VM_JUMPBOX}"

# KV이름 조합 (충돌 체크에 사용)
KV_NAME="kv-${PREFIX}-${KV_SUFFIX}"
# Storage Account 이름 (24자 이내)
PREFIX_NODASH="${PREFIX//-/}"
KV_SUFFIX_LOWER="$(echo "${KV_SUFFIX}" | tr 'A-Z' 'a-z')"
SA_FL="st${PREFIX_NODASH}${KV_SUFFIX_LOWER}fl"
SA_BK="st${PREFIX_NODASH}${KV_SUFFIX_LOWER}bk"

# Storage Account 이름 길이 체크 (3~24자)
for sa_name in "${SA_FL}" "${SA_BK}"; do
  sa_len=${#sa_name}
  if [[ "${sa_len}" -ge 3 && "${sa_len}" -le 24 ]]; then
    ok "Storage Account 이름: ${sa_name} (${sa_len}자)"
  else
    fail "Storage Account 이름: ${sa_name} (${sa_len}자) — 3~24자 제한 초과, prefix 또는 kv_suffix 조정 필요"
  fi
done

# ============================================================
# P3. Azure 인증 확인
# ============================================================
step_header "P3. Azure 인증"

if ! az account show --output none 2>/dev/null; then
  fail "az login이 필요합니다"
  fail "  az login (인터랙티브)"
  fail "  az login --service-principal -u <app-id> --password <pw> --tenant <tenant>"
  echo ""
  echo "  Azure 인증 없이 계속 진행할 수 없습니다."
  exit 1
fi

CURRENT_SUB=$(az account show --query "id" -o tsv 2>/dev/null)
CURRENT_TENANT=$(az account show --query "tenantId" -o tsv 2>/dev/null)
CURRENT_USER=$(az account show --query "user.name" -o tsv 2>/dev/null)
CURRENT_SUB_NAME=$(az account show --query "name" -o tsv 2>/dev/null)

ok "Azure 로그인: ${CURRENT_USER}"
ok "구독: ${CURRENT_SUB_NAME} (${CURRENT_SUB})"

# subscription_id 일치 여부
if [[ -n "${SUB_ID}" ]]; then
  if [[ "${CURRENT_SUB}" == "${SUB_ID}" ]]; then
    ok "구독 ID 일치: terraform.tfvars ↔ az login"
  else
    fail "구독 불일치!"
    fail "  terraform.tfvars: ${SUB_ID}"
    fail "  현재 로그인:       ${CURRENT_SUB}"
    info "  수정: az account set --subscription ${SUB_ID}"
  fi
fi

# tenant_id 일치 여부
if [[ -n "${TENANT_ID}" ]]; then
  if [[ "${CURRENT_TENANT}" == "${TENANT_ID}" ]]; then
    ok "테넌트 ID 일치: terraform.tfvars ↔ az login"
  else
    fail "테넌트 불일치!"
    fail "  terraform.tfvars: ${TENANT_ID}"
    fail "  현재 로그인:       ${CURRENT_TENANT}"
  fi
fi

# ============================================================
# P4. 권한 검증
# ============================================================
step_header "P4. 권한 검증"

CURRENT_OBJECT_ID=$(az ad signed-in-user show --query "id" -o tsv 2>/dev/null || echo "")
SCOPE="/subscriptions/${CURRENT_SUB}"

check_role() {
  local role_name="$1"
  local has_role
  has_role=$(az role assignment list \
    --assignee "${CURRENT_OBJECT_ID}" \
    --scope "${SCOPE}" \
    --query "[?roleDefinitionName=='${role_name}'].roleDefinitionName" \
    -o tsv 2>/dev/null || echo "")
  if [[ -n "${has_role}" ]]; then
    ok "역할: ${role_name} (구독 레벨)"
    return 0
  fi
  return 1
}

# Contributor 또는 Owner
if check_role "Contributor" || check_role "Owner"; then
  : # ok already printed
else
  warn "Contributor/Owner 역할 없음 — 리소스 생성 권한 확인 필요"
  info "  Custom 역할 또는 개별 권한이 있는 경우 무시 가능"
fi

# User Access Administrator (RBAC 할당용)
if check_role "User Access Administrator" || check_role "Owner"; then
  : # ok already printed
else
  warn "User Access Administrator 없음 — RBAC 역할 할당 실패 가능"
  info "  tofu apply 중 azurerm_role_assignment 리소스가 실패할 수 있습니다"
fi

# ============================================================
# P5. State Backend 확인
# ============================================================
step_header "P5. State Backend (Azure Blob)"

# backend.tf에서 State 설정 추출
BACKEND_TF="$(dirname "${TFVARS_PATH}")/backend.tf"
if [[ -f "${BACKEND_TF}" ]]; then
  STATE_RG=$(grep 'resource_group_name' "${BACKEND_TF}" | grep -v '^#' | head -1 | sed 's/.*= *"\(.*\)".*/\1/')
  STATE_ACCOUNT=$(grep 'storage_account_name' "${BACKEND_TF}" | grep -v '^#' | head -1 | sed 's/.*= *"\(.*\)".*/\1/')
  STATE_CONTAINER=$(grep 'container_name' "${BACKEND_TF}" | grep -v '^#' | head -1 | sed 's/.*= *"\(.*\)".*/\1/')
  STATE_KEY=$(grep '"key"' "${BACKEND_TF}" | grep -v '^#' | head -1 | sed 's/.*= *"\(.*\)".*/\1/')
else
  STATE_RG="rg-tfstate"
  STATE_ACCOUNT=""
  STATE_CONTAINER="tfstate"
  STATE_KEY="azure-k8s/main.tfstate"
fi

info "State RG:        ${STATE_RG}"
info "State Account:   ${STATE_ACCOUNT:-미감지}"
info "State Container: ${STATE_CONTAINER}"
info "State Key:       ${STATE_KEY}"

# State RG 존재 여부
if az group show -n "${STATE_RG}" --output none 2>/dev/null; then
  ok "State RG: ${STATE_RG} (존재)"
else
  fail "State RG: ${STATE_RG} 없음"
  info "  생성 방법: scripts/init-backend.sh 실행"
fi

# Storage Account 존재 여부
if [[ -n "${STATE_ACCOUNT}" ]]; then
  if az storage account show -n "${STATE_ACCOUNT}" --output none 2>/dev/null; then
    ok "State Storage Account: ${STATE_ACCOUNT} (존재)"

    # Container 존재 여부
    container_exists=$(az storage container exists \
      --account-name "${STATE_ACCOUNT}" \
      --name "${STATE_CONTAINER}" \
      --auth-mode login \
      --query "exists" -o tsv 2>/dev/null || echo "false")
    [[ "${container_exists}" == "true" ]] \
      && ok "State Container: ${STATE_CONTAINER} (존재)" \
      || fail "State Container: ${STATE_CONTAINER} 없음 (Storage Account는 존재)"

    # 현재 State 파일 잠금 여부 확인
    lease_state=$(az storage blob show \
      --account-name "${STATE_ACCOUNT}" \
      --container-name "${STATE_CONTAINER}" \
      --name "${STATE_KEY}" \
      --auth-mode login \
      --query "properties.lease.status" -o tsv 2>/dev/null || echo "unlocked")
    if [[ "${lease_state}" == "locked" ]]; then
      fail "State Lock 감지: ${STATE_KEY} — 다른 apply/plan이 실행 중이거나 중단됨"
      info "  해제: tofu force-unlock -force <lock-id>"
    else
      ok "State Lock: 없음 (정상)"
    fi
  else
    fail "State Storage Account: ${STATE_ACCOUNT} 없음"
    info "  scripts/init-backend.sh 실행 필요"
  fi
else
  warn "State Storage Account: backend.tf에서 감지 실패 — 수동 확인 필요"
fi

# ============================================================
# P6. Azure Resource Provider 등록 확인
# ============================================================
if step_enabled "P6"; then
  step_header "P6. Azure Resource Provider 등록"

  REQUIRED_PROVIDERS=(
    "Microsoft.ContainerService"
    "Microsoft.KubernetesConfiguration"
    "Microsoft.Dashboard"
    "Microsoft.DataProtection"
    "Microsoft.Monitor"
    "Microsoft.OperationalInsights"
    "Microsoft.Insights"
    "Microsoft.Network"
    "Microsoft.Compute"
    "Microsoft.Storage"
    "Microsoft.KeyVault"
    "Microsoft.ContainerRegistry"
  )

  UNREGISTERED=()
  for provider in "${REQUIRED_PROVIDERS[@]}"; do
    state=$(az provider show -n "${provider}" --query "registrationState" -o tsv 2>/dev/null || echo "Unknown")
    if [[ "${state}" == "Registered" ]]; then
      ok "Provider: ${provider}"
    elif [[ "${state}" == "Registering" ]]; then
      warn "Provider: ${provider} (등록 중 — 완료까지 몇 분 소요)"
    else
      fail "Provider: ${provider} (${state})"
      UNREGISTERED+=("${provider}")
    fi
  done

  if [[ ${#UNREGISTERED[@]} -gt 0 ]]; then
    if [[ "${FIX_PROVIDERS}" == "true" ]]; then
      info "  --fix-providers 옵션으로 자동 등록 시작..."
      for provider in "${UNREGISTERED[@]}"; do
        info "  등록 중: ${provider}"
        az provider register --namespace "${provider}" --wait 2>/dev/null && ok "  등록 완료: ${provider}" || warn "  등록 실패: ${provider}"
      done
    else
      info "  자동 등록: ./scripts/preflight.sh --fix-providers"
      info "  (또는 tofu apply 시 azurerm_resource_provider_registration이 자동 처리)"
    fi
  fi
fi

# ============================================================
# P7. 리소스 충돌 감지
# ============================================================
step_header "P7. 리소스 충돌 감지"

section "Soft-deleted Key Vault 충돌"
if [[ -n "${KV_NAME}" ]]; then
  deleted_kv=$(az keyvault list-deleted --query "[?name=='${KV_NAME}'].name" -o tsv 2>/dev/null || echo "")
  if [[ -n "${deleted_kv}" ]]; then
    fail "Soft-deleted Key Vault 발견: ${KV_NAME}"
    info "  해결 옵션:"
    info "  1) az keyvault purge --name ${KV_NAME}  (즉시 삭제)"
    info "  2) kv_suffix 변경으로 새 이름 사용"
  else
    ok "Key Vault 충돌 없음: ${KV_NAME}"
  fi
fi

section "기존 관리형 RG 충돌"
RG_CONFLICTS=0
for rg in "rg-${PREFIX}-common" "rg-${PREFIX}-mgmt" "rg-${PREFIX}-app1" "rg-${PREFIX}-app2"; do
  if az group show -n "${rg}" --output none 2>/dev/null; then
    rg_state=$(az group show -n "${rg}" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Unknown")
    warn "RG 이미 존재: ${rg} (${rg_state})"
    info "  이전 배포 잔여 RG이면 scripts/destroy.sh로 정리 후 재시도"
    ((RG_CONFLICTS++)) || true
  else
    ok "RG 없음 (clean): ${rg}"
  fi
done

section "ACR 이름 중복 확인"
if [[ -n "${ACR_NAME}" ]]; then
  acr_avail=$(az acr check-name -n "${ACR_NAME}" --query "nameAvailable" -o tsv 2>/dev/null || echo "unknown")
  if [[ "${acr_avail}" == "true" ]]; then
    ok "ACR 이름 사용 가능: ${ACR_NAME}"
  elif [[ "${acr_avail}" == "false" ]]; then
    acr_owner=$(az acr check-name -n "${ACR_NAME}" --query "reason" -o tsv 2>/dev/null || echo "")
    # 현재 구독 내 존재 vs 타인 소유 구분
    if az acr show -n "${ACR_NAME}" --output none 2>/dev/null; then
      warn "ACR 이미 존재 (현재 구독): ${ACR_NAME} — 재배포 시 사용 가능"
    else
      fail "ACR 이름 이미 사용 중 (다른 구독): ${ACR_NAME} — acr_name 변경 필요 (${acr_owner})"
    fi
  else
    warn "ACR 이름 가용성 확인 실패"
  fi
fi

# ============================================================
# P8. vCPU 쿼터 확인
# ============================================================
if step_enabled "P8"; then
  step_header "P8. vCPU 쿼터 확인 (${LOCATION})"

  # VM별 vCPU 수 조회 (az vm list-sizes 사용)
  get_vcpu() {
    local vm_size="$1"
    az vm list-sizes -l "${LOCATION}" --query "[?name=='${vm_size}'].numberOfCores" -o tsv 2>/dev/null | head -1
  }

  # 필요한 vCPU 계산 (기본 노드 수 기준)
  SYS_VCPU=$(get_vcpu "${VM_SYSTEM}"); SYS_VCPU="${SYS_VCPU:-2}"
  INGRESS_VCPU=$(get_vcpu "${VM_INGRESS}"); INGRESS_VCPU="${INGRESS_VCPU:-2}"
  JUMP_VCPU=$(get_vcpu "${VM_JUMPBOX}"); JUMP_VCPU="${JUMP_VCPU:-2}"

  SYS_NODES_TOTAL=$((SYS_VCPU * 3 * 3))      # 3 nodes × 3 clusters
  INGRESS_NODES_TOTAL=$((INGRESS_VCPU * 3 * 2)) # 3 nodes × 2 clusters (mgmt+app1)
  REQ_DSERIES=$((SYS_NODES_TOTAL + INGRESS_NODES_TOTAL))
  REQ_BSERIES=${JUMP_VCPU}

  info "예상 vCPU 필요량:"
  info "  System nodes   : ${VM_SYSTEM} × 3 nodes × 3 clusters = ${SYS_NODES_TOTAL} vCPU"
  info "  Ingress nodes  : ${VM_INGRESS} × 3 nodes × 2 clusters = ${INGRESS_NODES_TOTAL} vCPU"
  info "  Jumpbox        : ${VM_JUMPBOX} = ${JUMP_VCPU} vCPU"
  info "  D-Series 합계  : ${REQ_DSERIES} vCPU"
  info "  B-Series 합계  : ${REQ_BSERIES} vCPU"

  check_quota() {
    local family="$1" required="$2" label="$3"
    local current_used limit
    quota_json=$(az vm list-usage -l "${LOCATION}" \
      --query "[?contains(name.value, '${family}')]" \
      -o json 2>/dev/null || echo "[]")
    if [[ "${quota_json}" == "[]" ]]; then
      warn "쿼터 정보 조회 실패: ${label} — az vm list-usage 권한 확인"
      return
    fi
    current_used=$(echo "${quota_json}" | grep -o '"currentValue": *[0-9]*' | grep -o '[0-9]*' | head -1 || echo 0)
    limit=$(echo "${quota_json}" | grep -o '"limit": *[0-9]*' | grep -o '[0-9]*' | head -1 || echo 0)
    available=$((limit - current_used))

    if [[ "${available}" -ge "${required}" ]]; then
      ok "${label}: 사용 ${current_used}/${limit} — 가용 ${available} (필요: ${required})"
    else
      fail "${label}: 사용 ${current_used}/${limit} — 가용 ${available}, 필요 ${required} (부족!)"
      info "  Azure 포털에서 쿼터 증가 요청: Home > Quotas > Compute"
    fi
  }

  check_quota "standardDSv4Family"    "${REQ_DSERIES}" "Standard DSv4 Family"
  check_quota "standardBSFamily"      "${REQ_BSERIES}"  "Standard B Family (Jumpbox)"
  # Spot 쿼터 (Karpenter NAP에서 사용)
  check_quota "spotCores"             "0"               "Spot vCPU (Karpenter NAP 용)"
fi

# ============================================================
# P9. Addon 사전조건 (addon_repo_url 설정 시)
# ============================================================
step_header "P9. Addon 사전조건"

ADDON_REPO_URL=$(tfvar_str "addon_repo_url")
if [[ -z "${ADDON_REPO_URL}" ]]; then
  warn "addon_repo_url: 미설정 — Addon 자동 설치 건너뜀"
  info "  Addon을 자동 설치하려면 terraform.tfvars에 addon_repo_url 설정"
  info "  미설정 시 tofu apply 후 수동으로 addons/install.sh 실행"
else
  ok "addon_repo_url: ${ADDON_REPO_URL}"

  # Git 접근 가능 여부 (HTTP URL만 확인, SSH는 키 불필요)
  if echo "${ADDON_REPO_URL}" | grep -qE '^https://'; then
    if command -v git &>/dev/null && git ls-remote "${ADDON_REPO_URL}" HEAD &>/dev/null 2>&1; then
      ok "Git 레포 접근 가능: ${ADDON_REPO_URL}"
    else
      warn "Git 레포 접근 실패: ${ADDON_REPO_URL} — 인증 또는 URL 확인"
    fi
  else
    info "SSH URL은 런타임에 SSH 키로 인증 — 접근 여부 확인 생략"
  fi

  section "addon_env 필수 항목 확인"

  # LETSENCRYPT_EMAIL
  if addon_env_key "LETSENCRYPT_EMAIL"; then
    ok "addon_env.LETSENCRYPT_EMAIL: 설정됨"
  else
    warn "addon_env.LETSENCRYPT_EMAIL: 미설정 — cert-manager ClusterIssuer 생성 실패"
  fi

  # AZURE_SUBSCRIPTION_ID / AZURE_TENANT_ID
  for key in "AZURE_SUBSCRIPTION_ID" "AZURE_TENANT_ID"; do
    if addon_env_key "${key}"; then
      ok "addon_env.${key}: 설정됨"
    else
      warn "addon_env.${key}: 미설정 — 일부 addon 기능 제한"
    fi
  done

  # GITOPS_REPO_URL (선택 — 미설정 시 Flux skip)
  if addon_env_key "GITOPS_REPO_URL"; then
    ok "addon_env.GITOPS_REPO_URL: 설정됨 (Flux FluxConfig 활성화)"
    if ! tfvar_exists "flux_ssh_private_key"; then
      warn "flux_ssh_private_key: 미설정 — GitOps SSH 인증 실패 가능"
      info "  생성: ssh-keygen -t ed25519 -C flux-deploy -f ~/.ssh/flux-deploy-key -N ''"
    else
      ok "flux_ssh_private_key: 설정됨"
    fi
  else
    ok "addon_env.GITOPS_REPO_URL: 미설정 — Flux FluxConfig 자동 건너뜀 (다음 버전 과제)"
  fi
fi

# ============================================================
# 최종 요약 + 배포 순서
# ============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   Pre-flight 결과 요약                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  \033[32mPASS\033[0m : %-3d   \033[31mFAIL\033[0m : %-3d   \033[33mWARN\033[0m : %-3d                      ║\n" \
  "${PASS}" "${FAIL}" "${WARN}"
echo "╚══════════════════════════════════════════════════════════════╝"

if [[ "${FAIL}" -gt 0 ]]; then
  echo ""
  printf "  \033[31m✗ %d개 항목 실패 — 위 오류를 해결한 후 재실행하세요.\033[0m\n" "${FAIL}"
  exit 1
fi

# ============================================================
# 배포 순서 (모든 check 통과 시 출력)
# ============================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "\033[1;32m  ✓ 모든 사전 검증 통과 — tofu apply 진행 가능\033[0m\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  배포 순서 (tofu apply 자동 처리):"
echo ""
echo "  [1] Provider 등록"
echo "       └─ Microsoft.KubernetesConfiguration (Backup Extension 필수)"
echo ""
echo "  [2] Resource Groups"
echo "       └─ rg-${PREFIX}-common, rg-${PREFIX}-mgmt, rg-${PREFIX}-app1, rg-${PREFIX}-app2"
echo ""
echo "  [3] Network"
echo "       ├─ VNet (mgmt/app1/app2) + 풀메시 Peering"
echo "       ├─ Subnets (AKS / Bastion / Jumpbox / Private Endpoint)"
echo "       ├─ NSG (AKS / Bastion / Jumpbox)"
echo "       └─ Private DNS Zone (AKS / KV)"
echo ""
echo "  [4] Monitoring"
echo "       ├─ Log Analytics Workspace"
echo "       ├─ Azure Monitor Workspace (Managed Prometheus)"
echo "       ├─ Application Insights"
echo "       └─ Azure Managed Grafana (enable_grafana=true 시)"
echo ""
echo "  [5] Key Vault"
echo "       ├─ Key Vault (RBAC mode, Private Endpoint)"
echo "       └─ Deployer KV Administrator 역할 자동 부여"
echo ""
echo "  [6] ACR"
echo "       └─ Azure Container Registry (${ACR_NAME:-<acr_name>})"
echo ""
echo "  [7] Identity"
echo "       ├─ Control Plane MI (mgmt/app1/app2)"
echo "       ├─ Kubelet MI (mgmt/app1/app2)"
echo "       ├─ cert-manager MI + Workload Identity Federation"
echo "       └─ RBAC: AcrPull / NetworkContributor / DNS Zone Contributor"
echo ""
echo "  [8] AKS Clusters"
echo "       ├─ AKS (mgmt/app1/app2) — Private, Cilium CNI Overlay"
echo "       ├─ Ingress Node Pool (mgmt/app1)"
echo "       ├─ Azure Bastion + Jump VM"
echo "       └─ Jump VM CustomScript → cloud-init 완료 후 addons/install.sh 실행"
echo ""
echo "  [9] Backup"
echo "       ├─ Backup Vault + Policy"
echo "       ├─ Backup Extension (mgmt/app1/app2)"
echo "       └─ Backup Instance 연결"
echo ""
echo "  [10] Data Services (선택)"
echo "       ├─ Redis (enable_redis=true 시)"
echo "       ├─ MySQL (enable_mysql=true 시)"
echo "       └─ Service Bus (enable_servicebus=true 시)"
echo ""
echo "  [11] Addon 자동 설치 (addon_repo_url 설정 시, Jump VM에서 실행)"
echo "       ├─ cert-manager → Istio mTLS → Karpenter NodePool"
echo "       ├─ External Secrets → Reloader → Kyverno"
echo "       ├─ Flux v2 (GITOPS_REPO_URL 설정 시)"
echo "       └─ Kiali → OTel → Grafana 대시보드"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  다음 실행:"
echo "    tofu init   # 최초 실행 또는 provider 변경 후"
echo "    tofu plan   # 변경사항 미리보기"
echo "    tofu apply  # 배포 실행"
echo ""
