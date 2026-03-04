#!/usr/bin/env bash
# ============================================================
# scripts/pre-destroy.sh — tofu destroy 전 K8s 리소스 사전 정리
#
# tofu state 외부에서 생성된 Azure 리소스를 정리하여
# tofu destroy 시 충돌/잔여 리소스를 방지한다.
#
# 정리 대상:
#   1. LoadBalancer Service → Azure LB 해제
#   2. PersistentVolumeClaim → Azure Disk/File 해제
#   3. Flux GitOps Extension 제거
#   4. AKS Backup Extension 제거
#   5. Backup Instance 삭제 (Backup Vault)
#
# Usage:
#   chmod +x scripts/pre-destroy.sh
#   ./scripts/pre-destroy.sh [--cluster all] [--prefix k8s] [--dry-run]
#
# Prerequisites:
#   - kubectl, az, kubelogin 설치됨
#   - az login 완료
#   - Jump VM 또는 AKS Private Cluster 접근 가능 환경
# ============================================================

set -euo pipefail

# --- Default values ---
CLUSTER_TARGET="all"
DRY_RUN=false
PREFIX="${PREFIX:-k8s}"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      CLUSTER_TARGET="${2:?ERROR: --cluster requires a value (mgmt|app1|app2|all)}"
      shift 2
      ;;
    --prefix)
      PREFIX="${2:?ERROR: --prefix requires a value}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--cluster all|mgmt|app1|app2] [--prefix k8s] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# --cluster 값 검증
valid_targets="all mgmt app1 app2"
if [[ ! " ${valid_targets} " =~ " ${CLUSTER_TARGET} " ]]; then
  echo "ERROR: Invalid --cluster value '${CLUSTER_TARGET}'. Must be one of: ${valid_targets}" >&2
  exit 1
fi

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# --- Prerequisite check ---
for cmd in kubectl az kubelogin; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed." >&2
    exit 1
  fi
done

# --- 클러스터 목록 결정 ---
if [[ "${CLUSTER_TARGET}" == "all" ]]; then
  CLUSTERS=(mgmt app1 app2)
else
  CLUSTERS=("${CLUSTER_TARGET}")
fi

log "=== Pre-destroy cleanup ==="
log "Target: ${CLUSTER_TARGET}"
log "Prefix: ${PREFIX}"
log "Dry run: ${DRY_RUN}"
echo ""

# ============================================================
# Step 1-4: 클러스터별 K8s 리소스 정리
# ============================================================
for cluster in "${CLUSTERS[@]}"; do
  RG="rg-${PREFIX}-${cluster}"
  AKS="aks-${cluster}"

  log "--- Cleaning up cluster: ${cluster} (${RG}/${AKS}) ---"

  # AKS 클러스터 존재 여부 확인
  if ! az aks show -g "${RG}" -n "${AKS}" &>/dev/null; then
    log "  SKIP: Cluster ${AKS} not found in ${RG}"
    continue
  fi

  # kubeconfig 획득
  log "  Getting credentials for ${AKS}..."
  run az aks get-credentials -g "${RG}" -n "${AKS}" --overwrite-existing

  # 1) LoadBalancer Service 삭제
  log "  [1/4] Deleting LoadBalancer Services..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    kubectl get svc --all-namespaces -o wide 2>/dev/null | grep LoadBalancer || echo "  (no LoadBalancer services)"
  else
    LB_SVCS=$(kubectl get svc --all-namespaces -o json 2>/dev/null \
      | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true)
    if [[ -n "${LB_SVCS}" ]]; then
      for svc in ${LB_SVCS}; do
        ns="${svc%%/*}"
        name="${svc##*/}"
        log "    Deleting svc/${name} in ${ns}"
        kubectl delete svc "${name}" -n "${ns}" --ignore-not-found --timeout=60s || true
      done
    else
      log "    No LoadBalancer services found"
    fi
  fi

  # 2) PVC 삭제 (Azure Disk/File 해제)
  log "  [2/4] Deleting PersistentVolumeClaims..."
  run kubectl delete pvc --all-namespaces --all --ignore-not-found --timeout=120s || true

  # 3) Flux Extension 제거
  log "  [3/4] Removing Flux extension..."
  run az k8s-extension delete -g "${RG}" -c "${AKS}" \
    --cluster-type managedClusters -n flux --yes 2>/dev/null || true

  # 4) AKS Backup Extension 제거
  log "  [4/4] Removing AKS Backup extension..."
  run az k8s-extension delete -g "${RG}" -c "${AKS}" \
    --cluster-type managedClusters -n azure-aks-backup --yes 2>/dev/null || true

  echo ""
done

# ============================================================
# Step 5: Backup Instance 삭제 (Backup Vault)
# ============================================================
VAULT_RG="rg-${PREFIX}-common"
VAULT_NAME="bv-${PREFIX}"

log "--- Cleaning up Backup Instances (${VAULT_RG}/${VAULT_NAME}) ---"

if az dataprotection backup-vault show -g "${VAULT_RG}" -n "${VAULT_NAME}" &>/dev/null; then
  INSTANCES=$(az dataprotection backup-instance list \
    -g "${VAULT_RG}" --vault-name "${VAULT_NAME}" \
    --query "[].name" -o tsv 2>/dev/null || true)

  if [[ -n "${INSTANCES}" ]]; then
    for instance in ${INSTANCES}; do
      log "  Deleting backup instance: ${instance}"
      run az dataprotection backup-instance delete \
        -g "${VAULT_RG}" --vault-name "${VAULT_NAME}" \
        -n "${instance}" --yes || true
    done
  else
    log "  No backup instances found"
  fi
else
  log "  SKIP: Backup Vault ${VAULT_NAME} not found"
fi

echo ""
log "=== Pre-destroy cleanup complete ==="
log ""
log "Next step: tofu destroy"
