#!/usr/bin/env bash
# ============================================================
# scripts/destroy.sh — 인프라 전체 삭제 (rg-tfstate 제외)
#
# Azure 관리형 RG 삭제 제약으로 인해 2-Wave 순서로 삭제합니다.
#
#   Wave 1 (병렬): 클러스터 RG 삭제
#     rg-${PREFIX}-mgmt / app1 / app2
#     → AKS 클러스터가 삭제되면서 MC_rg-*_aks-*_* 자동 정리
#
#   Wave 2 (단독): Common RG 삭제
#     rg-${PREFIX}-common
#     → Azure Monitor Workspace 삭제 시 MA_mon-*_managed 자동 정리
#
#   직접 삭제 금지 (Azure 자동 관리):
#     - MA_mon-*_managed     : Monitor Workspace 종속 RG (Wave 2에서 자동 제거)
#     - MC_rg-*_aks-*_*      : AKS 노드 RG          (Wave 1에서 자동 제거)
#     - NetworkWatcherRG     : Azure Network Watcher (보존)
#     - rg-tfstate           : Terraform State 백엔드 (보존)
#
# Usage:
#   chmod +x scripts/destroy.sh
#   ./scripts/destroy.sh [--prefix k8s] [--skip-predestroy] [--dry-run]
#
# Options:
#   --prefix          리소스 네이밍 prefix (default: k8s)
#   --skip-predestroy K8s 사전 정리 건너뜀
#   --dry-run         실행 없이 동작 미리보기
#
# Prerequisites:
#   - az CLI 설치 및 az login 완료
# ============================================================

set -euo pipefail

# ============================================================
# 기본값 및 인수 파싱
# ============================================================
PREFIX="${PREFIX:-k8s}"
STATE_ACCOUNT="${STATE_ACCOUNT:-stk8stfstate2cfd}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
STATE_KEY="${STATE_KEY:-azure-k8s/main.tfstate}"
DRY_RUN=false
SKIP_PREDESTROY=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)         PREFIX="${2:?}";  shift 2 ;;
    --skip-predestroy) SKIP_PREDESTROY=true; shift ;;
    --dry-run)        DRY_RUN=true;    shift ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--prefix k8s] [--skip-predestroy] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# ============================================================
# 헬퍼
# ============================================================
log()  { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$*"; }
info() { printf "  \033[36m→\033[0m %s\n" "$*"; }

rg_exists() { az group show -n "$1" --output none 2>/dev/null; }

# RG 비동기 삭제 요청
fire_delete() {
  local rg="$1"
  if rg_exists "${rg}"; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      info "[DRY-RUN] az group delete -n ${rg} --yes --no-wait"
    else
      log "  삭제 요청: ${rg}"
      az group delete -n "${rg}" --yes --no-wait
    fi
    echo "${rg}"   # 존재했던 RG 반환
  else
    info "없음 (skip): ${rg}"
  fi
}

# RG 목록이 모두 사라질 때까지 대기 (+ MA_* / MC_* 자동 정리 확인)
wait_deleted() {
  local label="$1"; shift
  local targets=("$@")
  local auto_patterns=()

  [[ "${DRY_RUN}" == "true" ]] && return

  # Wave 1이면 MC_* 모니터링, Wave 2이면 MA_* 모니터링
  if [[ "${label}" == "Wave1" ]]; then
    auto_patterns=("MC_rg-${PREFIX}-")
  elif [[ "${label}" == "Wave2" ]]; then
    auto_patterns=("MA_mon-${PREFIX}" "ma_mon-${PREFIX}")
  fi

  log "  대기 중 (30초 간격 폴링)..."
  while true; do
    remaining=()
    for rg in "${targets[@]}"; do
      rg_exists "${rg}" && remaining+=("${rg}")
    done

    if [[ ${#remaining[@]} -eq 0 ]]; then
      ok "  ${label}: 관리형 RG 모두 삭제 완료"
      break
    fi

    # 자동 관리 RG 잔여 확인 (정보 표시용)
    for pat in "${auto_patterns[@]}"; do
      auto_count=$(az group list --query "[?starts_with(name, '${pat}')].name" -o tsv 2>/dev/null | wc -l | tr -d ' ')
      [[ "${auto_count}" -gt 0 ]] && info "  자동 정리 대기: ${pat}* (${auto_count}개)"
    done

    log "  남은 대상 (${#remaining[@]}개): ${remaining[*]}"
    sleep 30
  done

  # 자동 관리 RG 완전 소멸 대기
  for pat in "${auto_patterns[@]}"; do
    while true; do
      auto_count=$(az group list --query "[?starts_with(name, '${pat}')].name" -o tsv 2>/dev/null | wc -l | tr -d ' ')
      if [[ "${auto_count}" -eq 0 ]]; then
        ok "  자동 정리 완료: ${pat}*"
        break
      fi
      info "  자동 RG 정리 대기: ${pat}* (${auto_count}개 남음)..."
      sleep 30
    done
  done
}

# ============================================================
# 사전 조건 확인
# ============================================================
if ! command -v az &>/dev/null; then
  echo "ERROR: az CLI가 설치되지 않았습니다." >&2; exit 1
fi
if ! az account show --output none 2>/dev/null; then
  echo "ERROR: az login이 필요합니다." >&2; exit 1
fi

# ============================================================
# 배너
# ============================================================
echo ""
log "══════════════════════════════════════════════"
log " Azure-K8s 인프라 전체 삭제"
log "══════════════════════════════════════════════"
log " Prefix     : ${PREFIX}"
log " Dry-run    : ${DRY_RUN}"
log ""
log " 삭제 순서 (의존성 역순):"
log "   Wave 1 (병렬): rg-${PREFIX}-mgmt / app1 / app2"
log "             └→ AKS 삭제 → MC_* 자동 정리"
log "   Wave 2 (단독): rg-${PREFIX}-common"
log "             └→ Monitor Workspace 삭제 → MA_* 자동 정리"
log ""
log " 보존 대상 : rg-tfstate, NetworkWatcherRG"
log " 직접 삭제 금지 : MA_*, MC_* (자동 정리 대상)"
log "══════════════════════════════════════════════"
echo ""

# ============================================================
# Step 1: K8s 리소스 사전 정리
# ============================================================
if [[ "${SKIP_PREDESTROY}" == "false" ]]; then
  log "━━ Step 1/5: K8s 리소스 사전 정리 ━━"
  if [[ -f "${SCRIPT_DIR}/pre-destroy.sh" ]]; then
    PREDESTROY_ARGS=""
    [[ "${DRY_RUN}" == "true" ]] && PREDESTROY_ARGS="--dry-run"
    bash "${SCRIPT_DIR}/pre-destroy.sh" --prefix "${PREFIX}" ${PREDESTROY_ARGS} || {
      log "[WARN] pre-destroy.sh 일부 실패 — 계속 진행"
    }
  else
    info "pre-destroy.sh 없음 — 건너뜀"
  fi
else
  log "━━ Step 1/5: K8s 사전 정리 건너뜀 (--skip-predestroy) ━━"
fi
echo ""

# ============================================================
# Step 2: Wave 1 — 클러스터 RG 병렬 삭제
#   MC_rg-${PREFIX}-*_aks-*_* 는 AKS 삭제 시 자동 정리
# ============================================================
log "━━ Step 2/5: Wave 1 — 클러스터 RG 병렬 삭제 ━━"
info "MC_rg-${PREFIX}-* (AKS 노드 RG)는 AKS 삭제 시 자동 제거됩니다"
echo ""

WAVE1_TARGETS=()
for cluster in mgmt app1 app2; do
  rg="rg-${PREFIX}-${cluster}"
  hit=$(fire_delete "${rg}")
  [[ -n "${hit}" ]] && WAVE1_TARGETS+=("${hit}")
done

echo ""
if [[ ${#WAVE1_TARGETS[@]} -gt 0 ]]; then
  wait_deleted "Wave1" "${WAVE1_TARGETS[@]}"
else
  info "Wave 1 삭제 대상 없음 — 이미 삭제됨"
fi
echo ""

# ============================================================
# Step 3: Wave 2 — Common RG 삭제
#   MA_mon-${PREFIX}_*_managed 는 Monitor Workspace 삭제 시 자동 정리
# ============================================================
log "━━ Step 3/5: Wave 2 — Common RG 삭제 ━━"
info "MA_mon-${PREFIX}_*_managed (Monitor Workspace 관리 RG)는 자동 제거됩니다"
echo ""

WAVE2_TARGETS=()
hit=$(fire_delete "rg-${PREFIX}-common")
[[ -n "${hit}" ]] && WAVE2_TARGETS+=("${hit}")

echo ""
if [[ ${#WAVE2_TARGETS[@]} -gt 0 ]]; then
  wait_deleted "Wave2" "${WAVE2_TARGETS[@]}"
else
  info "Wave 2 삭제 대상 없음 — 이미 삭제됨"
fi
echo ""

# ============================================================
# Step 4: 잔여 자동 관리 RG 확인
# ============================================================
log "━━ Step 4/5: 잔여 자동 관리 RG 확인 ━━"

ORPHAN_FOUND=false
for pat in "MA_mon-${PREFIX}" "ma_mon-${PREFIX}" "MC_rg-${PREFIX}-"; do
  orphans=$(az group list --query "[?starts_with(name, '${pat}')].name" -o tsv 2>/dev/null || echo "")
  if [[ -n "${orphans}" ]]; then
    ORPHAN_FOUND=true
    while IFS= read -r orphan; do
      fail "잔여 자동 관리 RG: ${orphan}"
      info "  → 부모 리소스가 완전히 삭제되면 Azure가 자동 제거합니다"
      info "  → 수동 제거 금지 (Azure 내부 상태 손상 가능)"
    done <<< "${orphans}"
  fi
done
[[ "${ORPHAN_FOUND}" == "false" ]] && ok "잔여 자동 관리 RG 없음 (정상)"
echo ""

# ============================================================
# Step 5: Terraform state blob 삭제
# ============================================================
log "━━ Step 5/5: Terraform state blob 삭제 ━━"

if [[ "${DRY_RUN}" == "true" ]]; then
  info "[DRY-RUN] az storage blob delete --account-name ${STATE_ACCOUNT} ..."
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
    ok "State blob 삭제: ${STATE_KEY}"
  else
    info "State blob 없음 — 이미 삭제됨"
  fi
fi

# ============================================================
# 완료
# ============================================================
echo ""
log "══════════════════════════════════════════════"
log " 삭제 완료"
log "══════════════════════════════════════════════"
log ""
log " 다음 배포:"
log "   tofu init"
log "   ./scripts/preflight.sh   # 사전 검증"
log "   tofu apply"
