#!/usr/bin/env bash
# ============================================================
# check-resources.sh — Phase 1 완료 후 Azure 리소스 존재 여부 검증
#
# KeyVault를 제외한 모든 Terraform 관리 리소스를 확인합니다.
#
# Usage:
#   ./check-resources.sh [--prefix k8s] [--location koreacentral] \
#                        [--acr-name <acr_name>] [--kv-suffix <suffix>] \
#                        [--no-grafana]
#
# Options:
#   --prefix       리소스 네이밍 prefix (default: k8s)
#   --location     Azure region (default: koreacentral)
#   --acr-name     ACR 이름 (default: acr${PREFIX})
#   --kv-suffix    kv_suffix 값 — Storage Account 이름 생성에 필요
#   --no-grafana   Grafana 리소스 검증 건너뜀
# ============================================================
set -euo pipefail

# --- Defaults ---
PREFIX="k8s"
LOCATION="koreacentral"
ACR_NAME=""
KV_SUFFIX=""
CHECK_GRAFANA=true

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="$2";    shift 2 ;;
    --location)  LOCATION="$2";  shift 2 ;;
    --acr-name)  ACR_NAME="$2";  shift 2 ;;
    --kv-suffix) KV_SUFFIX="$2"; shift 2 ;;
    --no-grafana) CHECK_GRAFANA=false; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- Derived names (locals.tf와 동일한 규칙) ---
RG_COMMON="rg-${PREFIX}-common"
PREFIX_NODASH="${PREFIX//-/}"
KV_SUFFIX_LOWER="$(echo "${KV_SUFFIX}" | tr "A-Z" "a-z")"

PASS=0
FAIL=0
WARN=0

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; ((PASS++)) || true; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$*"; ((FAIL++)) || true; }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; ((WARN++)) || true; }
section() { echo ""; log "--- $* ---"; }

# az CLI 설치 확인
if ! command -v az &>/dev/null; then
  echo "ERROR: 'az' CLI가 설치되지 않았습니다." >&2
  exit 1
fi

# az 로그인 상태 확인
if ! az account show --output none 2>/dev/null; then
  echo "ERROR: az login이 필요합니다." >&2
  exit 1
fi

# ============================================================
# Helper functions
# ============================================================

check_rg() {
  local name="$1"
  if az group show --name "$name" --output none 2>/dev/null; then
    ok "Resource Group: $name"
  else
    fail "Resource Group: $name (없음)"
  fi
}

check_vnet() {
  local name="$1" rg="$2"
  if az network vnet show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "VNet: $name"
  else
    fail "VNet: $name (없음)"
  fi
}

check_nsg() {
  local name="$1" rg="$2"
  if az network nsg show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "NSG: $name"
  else
    fail "NSG: $name (없음)"
  fi
}

check_private_dns_zone() {
  local name="$1" rg="$2"
  if az network private-dns zone show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "Private DNS Zone: $name"
  else
    fail "Private DNS Zone: $name (없음)"
  fi
}

check_law() {
  local name="$1" rg="$2"
  if az monitor log-analytics workspace show --resource-group "$rg" --workspace-name "$name" --output none 2>/dev/null; then
    ok "Log Analytics Workspace: $name"
  else
    fail "Log Analytics Workspace: $name (없음)"
  fi
}

check_monitor_workspace() {
  local name="$1" rg="$2"
  if az resource show \
      --resource-group "$rg" \
      --name "$name" \
      --resource-type "microsoft.monitor/accounts" \
      --output none 2>/dev/null; then
    ok "Monitor Workspace: $name"
  else
    fail "Monitor Workspace: $name (없음)"
  fi
}

check_app_insights() {
  local name="$1" rg="$2"
  if az monitor app-insights component show --resource-group "$rg" --app "$name" --output none 2>/dev/null; then
    ok "Application Insights: $name"
  else
    fail "Application Insights: $name (없음)"
  fi
}

check_grafana() {
  local name="$1" rg="$2"
  if az grafana show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "Managed Grafana: $name"
  else
    fail "Managed Grafana: $name (없음)"
  fi
}

check_acr() {
  local name="$1" rg="$2"
  if az acr show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "ACR: $name"
  else
    fail "ACR: $name (없음)"
  fi
}

check_identity() {
  local name="$1" rg="$2"
  if az identity show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "Managed Identity: $name"
  else
    fail "Managed Identity: $name (없음)"
  fi
}

check_aks() {
  local name="$1" rg="$2"
  if az aks show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    local state
    state=$(az aks show --resource-group "$rg" --name "$name" \
      --query "provisioningState" --output tsv 2>/dev/null || echo "Unknown")
    if [[ "$state" == "Succeeded" ]]; then
      ok "AKS Cluster: $name (Succeeded)"
    else
      warn "AKS Cluster: $name (존재하지만 상태: $state)"
    fi
  else
    fail "AKS Cluster: $name (없음)"
  fi
}

check_backup_vault() {
  local name="$1" rg="$2"
  if az dataprotection backup-vault show \
      --resource-group "$rg" --vault-name "$name" --output none 2>/dev/null; then
    ok "Backup Vault: $name"
  else
    fail "Backup Vault: $name (없음)"
  fi
}

check_storage() {
  local name="$1" rg="$2" label="$3"
  if az storage account show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "Storage Account ($label): $name"
  else
    fail "Storage Account ($label): $name (없음)"
  fi
}

check_vm() {
  local name="$1" rg="$2"
  if az vm show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "VM: $name"
  else
    fail "VM: $name (없음)"
  fi
}

check_bastion() {
  local name="$1" rg="$2"
  if az network bastion show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "Bastion: $name"
  else
    fail "Bastion: $name (없음)"
  fi
}

check_pip() {
  local name="$1" rg="$2"
  if az network public-ip show --resource-group "$rg" --name "$name" --output none 2>/dev/null; then
    ok "Public IP: $name"
  else
    fail "Public IP: $name (없음)"
  fi
}

# ============================================================
# Main checks
# ============================================================

log "============================================================"
log "Azure 리소스 존재 여부 검증 (KeyVault 제외)"
log "  Prefix   : ${PREFIX}"
log "  Location : ${LOCATION}"
log "  RG Common: ${RG_COMMON}"
log "============================================================"

# ----------------------------------------------------------
# 1. Resource Groups
# ----------------------------------------------------------
section "Resource Groups"
check_rg "${RG_COMMON}"
for cluster in mgmt app1 app2; do
  check_rg "rg-${PREFIX}-${cluster}"
done

# ----------------------------------------------------------
# 2. Network
# ----------------------------------------------------------
section "Network — VNets"
for vnet in mgmt app1 app2; do
  check_vnet "vnet-${vnet}" "${RG_COMMON}"
done

section "Network — NSGs"
for nsg in mgmt app1 app2; do
  check_nsg "nsg-aks-${nsg}" "${RG_COMMON}"
done
check_nsg "nsg-bastion" "${RG_COMMON}"
check_nsg "nsg-jumpbox" "${RG_COMMON}"

section "Network — Private DNS Zone (AKS)"
check_private_dns_zone "privatelink.${LOCATION}.azmk8s.io" "${RG_COMMON}"

# ----------------------------------------------------------
# 3. Monitoring
# ----------------------------------------------------------
section "Monitoring"
check_law        "law-${PREFIX}"   "${RG_COMMON}"
check_monitor_workspace "mon-${PREFIX}" "${RG_COMMON}"
check_app_insights "appi-${PREFIX}" "${RG_COMMON}"

if [[ "${CHECK_GRAFANA}" == "true" ]]; then
  check_grafana "grafana-${PREFIX}" "${RG_COMMON}"
else
  echo "  - Grafana 검증 건너뜀 (--no-grafana)"
fi

# ----------------------------------------------------------
# 4. ACR
# ----------------------------------------------------------
section "Container Registry"
if [[ -z "${ACR_NAME}" ]]; then
  warn "ACR 이름이 지정되지 않음 (--acr-name 필요) — 건너뜀"
else
  check_acr "${ACR_NAME}" "${RG_COMMON}"
fi

# ----------------------------------------------------------
# 5. Managed Identities
# ----------------------------------------------------------
section "Managed Identities"
for cluster in mgmt app1 app2; do
  check_identity "mi-aks-cp-${cluster}"      "${RG_COMMON}"
  check_identity "mi-aks-kubelet-${cluster}" "${RG_COMMON}"
  check_identity "mi-cert-manager-${cluster}" "${RG_COMMON}"
done

# ----------------------------------------------------------
# 6. AKS Clusters
# ----------------------------------------------------------
section "AKS Clusters"
for cluster in mgmt app1 app2; do
  check_aks "aks-${cluster}" "rg-${PREFIX}-${cluster}"
done

# ----------------------------------------------------------
# 7. Backup
# ----------------------------------------------------------
section "Backup"
check_backup_vault "bv-${PREFIX}" "${RG_COMMON}"

# ----------------------------------------------------------
# 8. Storage Accounts
# ----------------------------------------------------------
section "Storage Accounts"
if [[ -z "${KV_SUFFIX}" ]]; then
  warn "kv_suffix가 지정되지 않음 (--kv-suffix 필요) — Storage Account 검증 건너뜀"
else
  check_storage "st${PREFIX_NODASH}${KV_SUFFIX_LOWER}fl" "${RG_COMMON}" "Flow Logs"
  check_storage "st${PREFIX_NODASH}${KV_SUFFIX_LOWER}bk" "${RG_COMMON}" "Backup Staging"
fi

# ----------------------------------------------------------
# 9. Jumpbox & Bastion
# ----------------------------------------------------------
section "Jumpbox & Bastion"
# jumpbox/bastion은 mgmt 클러스터 RG에 위치
RG_MGMT="rg-${PREFIX}-mgmt"
check_vm      "vm-jumpbox"          "${RG_MGMT}"
check_bastion "bastion-${PREFIX}"   "${RG_MGMT}"
check_pip     "pip-bastion"         "${RG_MGMT}"

# ============================================================
# Summary
# ============================================================
echo ""
log "============================================================"
log "검증 결과 요약"
log "  PASS : ${PASS}"
log "  WARN : ${WARN}"
log "  FAIL : ${FAIL}"
log "============================================================"

if [[ "${FAIL}" -gt 0 ]]; then
  echo ""
  echo "  일부 리소스가 존재하지 않습니다."
  echo "  'tofu apply'가 완료되었는지 확인하세요."
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo ""
  echo "  모든 리소스가 존재하지만 일부 상태를 확인하세요."
  exit 0
else
  echo ""
  echo "  모든 리소스가 정상적으로 존재합니다."
  exit 0
fi
