#!/usr/bin/env bash
# ============================================================
# scripts/destroy.sh — 인프라 전체 삭제 (rg-tfstate 제외)
#
# 동작 순서:
#   1. K8s 리소스 사전 정리 (pre-destroy.sh)
#   2. 관리형 RG 비동기 병렬 삭제 (az group delete --no-wait)
#   3. 모든 삭제 완료 대기
#   4. Terraform state blob 삭제 (다음 fresh 배포 준비)
#
# 보존 대상 (삭제 안 함):
#   - rg-tfstate : Terraform state 백엔드 (별도 생명주기)
#
# Usage:
#   chmod +x scripts/destroy.sh
#   ./scripts/destroy.sh [--prefix k8s] [--skip-predestroy] [--dry-run]
#
# Prerequisites:
#   - az CLI 설치 및 az login 완료
#   - STATE_ACCOUNT 환경변수 (기본: stk8stfstate2cfd)
# ============================================================

set -euo pipefail

# --- Default values ---
PREFIX="${PREFIX:-k8s}"
STATE_ACCOUNT="${STATE_ACCOUNT:-stk8stfstate2cfd}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
STATE_KEY="${STATE_KEY:-azure-k8s/main.tfstate}"
DRY_RUN=false
SKIP_PREDESTROY=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="${2:?ERROR: --prefix requires a value}"
      shift 2
      ;;
    --skip-predestroy)
      SKIP_PREDESTROY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--prefix k8s] [--skip-predestroy] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

# --- Prerequisite check ---
if ! command -v az &>/dev/null; then
  echo "ERROR: 'az' is not installed." >&2
  exit 1
fi

if ! az account show &>/dev/null; then
  echo "ERROR: Not logged in to Azure. Run 'az login' first." >&2
  exit 1
fi

# --- 관리형 RG 목록 (rg-tfstate 제외) ---
MANAGED_RGS=(
  "rg-${PREFIX}-common"
  "rg-${PREFIX}-mgmt"
  "rg-${PREFIX}-app1"
  "rg-${PREFIX}-app2"
)

log "============================================"
log " Azure-K8s 인프라 전체 삭제"
log "============================================"
log "Prefix:         ${PREFIX}"
log "Managed RGs:    ${MANAGED_RGS[*]}"
log "Skip-predestroy: ${SKIP_PREDESTROY}"
log "Dry-run:        ${DRY_RUN}"
log "State account:  ${STATE_ACCOUNT}"
log ""
log "[주의] rg-tfstate (state 백엔드)는 삭제하지 않습니다."
echo ""

# ============================================================
# Step 1: K8s 리소스 사전 정리
# ============================================================
if [[ "${SKIP_PREDESTROY}" == "false" ]]; then
  log "=== Step 1/4: K8s 리소스 사전 정리 (pre-destroy.sh) ==="
  if [[ -f "${SCRIPT_DIR}/pre-destroy.sh" ]]; then
    PREDESTROY_ARGS=""
    [[ "${DRY_RUN}" == "true" ]] && PREDESTROY_ARGS="--dry-run"
    bash "${SCRIPT_DIR}/pre-destroy.sh" --prefix "${PREFIX}" ${PREDESTROY_ARGS} || {
      log "[WARN] pre-destroy.sh 일부 실패 — 계속 진행"
    }
  else
    log "[SKIP] pre-destroy.sh 파일 없음"
  fi
else
  log "=== Step 1/4: K8s 사전 정리 건너뜀 (--skip-predestroy) ==="
fi
echo ""

# ============================================================
# Step 2: 관리형 RG 비동기 병렬 삭제
# ============================================================
log "=== Step 2/4: 관리형 RG 비동기 삭제 시작 ==="

EXISTING_RGS=()
for rg in "${MANAGED_RGS[@]}"; do
  if az group show -n "${rg}" &>/dev/null 2>&1; then
    EXISTING_RGS+=("${rg}")
    if [[ "${DRY_RUN}" == "true" ]]; then
      log "  [DRY-RUN] az group delete -n ${rg} --yes --no-wait"
    else
      log "  Queuing deletion: ${rg}"
      az group delete -n "${rg}" --yes --no-wait
    fi
  else
    log "  SKIP (not found): ${rg}"
  fi
done

if [[ ${#EXISTING_RGS[@]} -eq 0 ]]; then
  log "  삭제할 RG 없음 — 이미 삭제되었거나 아직 생성되지 않음"
fi

echo ""

# ============================================================
# Step 3: 모든 RG 삭제 완료 대기
# ============================================================
if [[ "${DRY_RUN}" == "false" && ${#EXISTING_RGS[@]} -gt 0 ]]; then
  log "=== Step 3/4: RG 삭제 완료 대기 (30초 간격 폴링) ==="

  while true; do
    remaining=()
    for rg in "${EXISTING_RGS[@]}"; do
      if az group show -n "${rg}" &>/dev/null 2>&1; then
        remaining+=("${rg}")
      else
        log "  ✓ 삭제 완료: ${rg}"
      fi
    done

    if [[ ${#remaining[@]} -eq 0 ]]; then
      log "  모든 RG 삭제 완료"
      break
    fi

    log "  대기 중 (${#remaining[@]}개 남음): ${remaining[*]}"
    EXISTING_RGS=("${remaining[@]}")
    sleep 30
  done
else
  log "=== Step 3/4: 대기 건너뜀 (dry-run 또는 삭제 대상 없음) ==="
fi

echo ""

# ============================================================
# Step 4: Terraform state blob 삭제 (fresh 재배포 준비)
# ============================================================
log "=== Step 4/4: Terraform state blob 삭제 ==="

if [[ "${DRY_RUN}" == "true" ]]; then
  log "  [DRY-RUN] az storage blob delete --account-name ${STATE_ACCOUNT} --container-name ${STATE_CONTAINER} --name ${STATE_KEY}"
else
  if az storage blob show \
      --account-name "${STATE_ACCOUNT}" \
      --container-name "${STATE_CONTAINER}" \
      --name "${STATE_KEY}" \
      --auth-mode login &>/dev/null 2>&1; then
    az storage blob delete \
      --account-name "${STATE_ACCOUNT}" \
      --container-name "${STATE_CONTAINER}" \
      --name "${STATE_KEY}" \
      --auth-mode login
    log "  ✓ State blob 삭제 완료: ${STATE_KEY}"
  else
    log "  SKIP: State blob 없음 (이미 삭제됨)"
  fi
fi

echo ""
log "============================================"
log " 삭제 완료"
log "============================================"
log ""
log "다음 배포:"
log "  tofu init"
log "  tofu apply"
