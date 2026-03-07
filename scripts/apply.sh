#!/usr/bin/env bash
# ============================================================
# scripts/apply.sh — tofu apply 래퍼 (로그 자동 저장)
#
# Usage:
#   ./scripts/apply.sh [tofu apply 옵션...]
#   ./scripts/apply.sh -auto-approve
#   ./scripts/apply.sh -target=module.aks
#
# 로그: logs/apply/YYYYMMDD_HHMMSS.log
# ============================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs/apply"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[LOG] 로그 저장 위치: ${LOG_FILE}"
echo "[LOG] 시작 시각: $(date '+%Y-%m-%dT%H:%M:%S')"
echo ""

cd "${REPO_ROOT}"

if ! command -v tofu &>/dev/null; then
  echo "ERROR: tofu CLI가 설치되지 않았습니다." >&2; exit 1
fi
if ! az account show --output none 2>/dev/null; then
  echo "ERROR: az login이 필요합니다." >&2; exit 1
fi

# tfvars에서 ACR/KV 이름 읽기
SUB_ID=$(az account show --query id -o tsv 2>/dev/null)
ACR_NAME=$(grep -v '^[[:space:]]*#' "${REPO_ROOT}/terraform.tfvars" 2>/dev/null \
  | grep 'acr_name' | sed 's/.*= *"\(.*\)".*/\1/' | head -1 || echo "bocopile")
KV_SUFFIX=$(grep -v '^[[:space:]]*#' "${REPO_ROOT}/terraform.tfvars" 2>/dev/null \
  | grep 'kv_suffix' | sed 's/.*= *"\(.*\)".*/\1/' | head -1 || echo "9340")

# ============================================================
# PRE-CLEANUP: 고아(orphaned) Diagnostic Settings 정리
#
# 발생 원인: azurerm provider가 diagnostic setting을 Azure에 생성했지만
#           타임아웃/에러로 state에 저장하지 못한 경우 발생.
#           다음 apply에서 "already exists" 충돌로 실패함.
#
# 처리 방식: state에 없고 Azure에만 존재하는 경우에만 삭제.
#           state에 정상 등록된 리소스는 건드리지 않음.
# ============================================================
cleanup_orphaned_diag_settings() {
  echo "[PRE-CLEANUP] ── Orphaned Diagnostic Settings 확인 중 ──"

  # state에 없고 Azure에 존재하면 삭제
  _delete_if_orphaned() {
    local state_key="$1"
    local az_resource="$2"
    local diag_name="$3"

    if ! tofu state show "${state_key}" &>/dev/null 2>&1; then
      if az monitor diagnostic-settings show \
          --name "${diag_name}" \
          --resource "${az_resource}" \
          --output none 2>/dev/null; then
        az monitor diagnostic-settings delete \
          --name "${diag_name}" \
          --resource "${az_resource}" 2>/dev/null && \
          echo "[PRE-CLEANUP] 삭제 완료 (고아 리소스): ${diag_name}"
      fi
    fi
  }

  # 1. 구독 레벨 Activity Log (RG 무관하게 항상 시도)
  _delete_if_orphaned \
    "module.monitoring.azurerm_monitor_diagnostic_setting.activity_log" \
    "/subscriptions/${SUB_ID}" \
    "diag-activity-to-law"

  # 2. ACR — RG 존재 여부와 무관하게 리소스 경로로 직접 시도
  #    (이전 apply에서 생성 후 state 미저장 → 동일 이름 ACR 재생성 시 충돌)
  local ACR_RESOURCE="/subscriptions/${SUB_ID}/resourceGroups/rg-k8s-common/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}"
  _delete_if_orphaned \
    "module.acr.azurerm_monitor_diagnostic_setting.acr[0]" \
    "${ACR_RESOURCE}" \
    "diag-acr-to-law"

  # 3. KV — 동일 이유로 직접 경로 사용
  local KV_RESOURCE="/subscriptions/${SUB_ID}/resourceGroups/rg-k8s-common/providers/Microsoft.KeyVault/vaults/kv-k8s-${KV_SUFFIX}"
  _delete_if_orphaned \
    "module.keyvault.azurerm_monitor_diagnostic_setting.kv[0]" \
    "${KV_RESOURCE}" \
    "diag-kv-k8s-${KV_SUFFIX}"

  # 4. AKS Control Plane (mgmt/app1/app2) — RG가 있을 때만
  for cluster in mgmt app1 app2; do
    local RG="rg-k8s-${cluster}"
    if az group show -n "${RG}" --output none 2>/dev/null; then
      local AKS_ID
      AKS_ID=$(az aks list -g "${RG}" --query "[0].id" -o tsv 2>/dev/null || true)
      if [[ -n "${AKS_ID}" ]]; then
        _delete_if_orphaned \
          "module.aks.azurerm_monitor_diagnostic_setting.aks[\"${cluster}\"]" \
          "${AKS_ID}" \
          "diag-aks-${cluster}"
      fi
    fi
  done

  # 5. Key Vault Secret — flux-ssh-private-key
  if az group show -n rg-k8s-common --output none 2>/dev/null; then
    local KV_NAME_SECRET
    KV_NAME_SECRET=$(az keyvault list -g rg-k8s-common --query "[0].name" -o tsv 2>/dev/null || true)
    if [[ -n "${KV_NAME_SECRET}" ]]; then
      if ! tofu state show 'azurerm_key_vault_secret.flux_ssh_key[0]' &>/dev/null 2>&1; then
        if az keyvault secret show \
            --vault-name "${KV_NAME_SECRET}" \
            --name flux-ssh-private-key \
            --output none 2>/dev/null; then
          az keyvault secret delete \
            --vault-name "${KV_NAME_SECRET}" \
            --name flux-ssh-private-key 2>/dev/null && \
            echo "[PRE-CLEANUP] 삭제 완료 (고아 리소스): flux-ssh-private-key"
          sleep 5
          az keyvault secret purge \
            --vault-name "${KV_NAME_SECRET}" \
            --name flux-ssh-private-key 2>/dev/null || true
        fi
      fi
    fi
  fi

  # 6. Jump VM CustomScript Extension (addon-install)
  #    cloud-init 통합으로 Extension 리소스 제거 → Azure에 남은 고아 Extension 정리
  local VM_RG="rg-k8s-mgmt"
  local VM_NAME="vm-jumpbox"
  local EXT_NAME="addon-install"
  if ! tofu state show 'module.aks.azurerm_virtual_machine_extension.jumpbox_addon' &>/dev/null 2>&1; then
    if az vm extension show -g "${VM_RG}" --vm-name "${VM_NAME}" -n "${EXT_NAME}" \
        --output none 2>/dev/null; then
      echo "[PRE-CLEANUP] Jump VM Extension 고아 리소스 삭제: ${EXT_NAME}"
      az vm extension delete -g "${VM_RG}" --vm-name "${VM_NAME}" -n "${EXT_NAME}" 2>/dev/null && \
        echo "[PRE-CLEANUP] 삭제 완료: ${EXT_NAME}" || true
    fi
  fi

  echo "[PRE-CLEANUP] 완료"
  echo ""
}

# ============================================================
# AUTO-IMPORT: apply 실패 후 "already exists" 리소스 자동 import
#
# azurerm provider 버그: Azure에 리소스를 생성했지만 state에 저장 못한 경우.
# tofu import로 state에 등록 후 재apply하면 정상 처리됨.
# ============================================================
import_known_diag_settings() {
  echo "[AUTO-IMPORT] ── 알려진 Diagnostic Settings import 시도 ──"

  _import_if_missing() {
    local state_key="$1"
    local resource_id="$2"

    if ! tofu state show "${state_key}" &>/dev/null 2>&1; then
      echo "[AUTO-IMPORT] 시도: ${state_key}"
      if tofu import "${state_key}" "${resource_id}" 2>/dev/null; then
        echo "[AUTO-IMPORT] 성공: ${state_key}"
      else
        echo "[AUTO-IMPORT] 스킵 (리소스 없음 또는 import 불가): ${state_key}"
      fi
    fi
  }

  # 구독 레벨 Activity Log
  _import_if_missing \
    "module.monitoring.azurerm_monitor_diagnostic_setting.activity_log" \
    "/subscriptions/${SUB_ID}|diag-activity-to-law"

  # ACR
  _import_if_missing \
    "module.acr.azurerm_monitor_diagnostic_setting.acr[0]" \
    "/subscriptions/${SUB_ID}/resourceGroups/rg-k8s-common/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}|diag-acr-to-law"

  # KV
  _import_if_missing \
    "module.keyvault.azurerm_monitor_diagnostic_setting.kv[0]" \
    "/subscriptions/${SUB_ID}/resourceGroups/rg-k8s-common/providers/Microsoft.KeyVault/vaults/kv-k8s-${KV_SUFFIX}|diag-kv-k8s-${KV_SUFFIX}"

  # AKS (RG가 존재할 때만)
  for cluster in mgmt app1 app2; do
    local aks_state_key="module.aks.azurerm_monitor_diagnostic_setting.aks[\"${cluster}\"]"
    if ! tofu state show "${aks_state_key}" &>/dev/null 2>&1; then
      local AKS_ID
      AKS_ID=$(az aks list -g "rg-k8s-${cluster}" --query "[0].id" -o tsv 2>/dev/null || true)
      if [[ -n "${AKS_ID}" ]]; then
        _import_if_missing \
          "${aks_state_key}" \
          "${AKS_ID}|diag-aks-${cluster}"
      fi
    fi
  done

  echo "[AUTO-IMPORT] 완료"
  echo ""
}

# ============================================================
# MAIN: apply 실행 + "already exists" 오류 시 자동 import 후 재시도
# ============================================================
cleanup_orphaned_diag_settings

MAX_ATTEMPTS=3
ATTEMPT=0

while [[ ${ATTEMPT} -lt ${MAX_ATTEMPTS} ]]; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] tofu apply 시작 (시도 ${ATTEMPT}/${MAX_ATTEMPTS})"
  echo ""

  # apply 전 로그 라인 수 기록 (이번 apply 결과만 확인하기 위해)
  LINES_BEFORE=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)

  APPLY_EXIT=0
  tofu apply "$@" || APPLY_EXIT=$?

  if [[ ${APPLY_EXIT} -eq 0 ]]; then
    echo ""
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] tofu apply 완료"
    exit 0
  fi

  # 이번 apply 출력에서 "already exists" 여부 확인
  if tail -n +"$((LINES_BEFORE + 1))" "${LOG_FILE}" | grep -q "already exists" \
      && [[ ${ATTEMPT} -lt ${MAX_ATTEMPTS} ]]; then
    echo ""
    echo "[RETRY] 'already exists' 오류 감지 → 자동 import 후 재시도"
    import_known_diag_settings
  else
    echo ""
    echo "[ERROR] tofu apply 실패 (복구 불가 오류 또는 최대 재시도 초과)"
    exit ${APPLY_EXIT}
  fi
done
