#!/usr/bin/env bash
# ============================================================
# scripts/pre-destroy.sh — tofu destroy 전 K8s 리소스 사전 정리
#
# tofu state 외부에서 생성된 Azure 리소스를 정리하여
# tofu destroy 시 충돌/잔여 리소스를 방지한다.
#
# kubectl 명령은 az aks command invoke를 통해 실행하므로
# VPN / Jump VM 없이 어느 환경에서나 동작한다.
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
#   ./scripts/pre-destroy.sh [--cluster all|mgmt|app1|app2] [--prefix k8s] [--dry-run]
#
# Prerequisites:
#   - az CLI 설치 및 az login 완료
#   (kubectl / kubelogin 불필요 — az aks command invoke 사용)
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

# az aks command invoke 래퍼
# - Azure API를 통해 kubectl 명령을 실행하므로 VPN 불필요
# - DRY_RUN=true 이면 실행할 명령을 출력만 하고 스킵
# - 내부 명령 실패 시 exit code를 그대로 전파 (set -e 연동)
# Usage: aks_invoke <rg> <aks> <command>
aks_invoke() {
  local rg="$1" aks="$2" cmd="$3"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY-RUN] invoke on ${aks}: ${cmd}"
    return 0
  fi

  az aks command invoke \
    --resource-group "${rg}" \
    --name "${aks}" \
    --command "${cmd}" \
    --query "logs" \
    --output tsv
}

# --- Prerequisite check ---
if ! command -v az &>/dev/null; then
  echo "ERROR: 'az' is not installed." >&2
  exit 1
fi

if ! az account show &>/dev/null; then
  echo "ERROR: Not logged in to Azure. Run 'az login' first." >&2
  exit 1
fi

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

  # 1) LoadBalancer Service 삭제
  # go-template 사용 (jq 의존성 없음 — az aks command invoke 환경에서도 안전)
  log "  [1/4] Deleting LoadBalancer Services..."
  # shellcheck disable=SC2016
  LB_CMD='svcs=$(kubectl get svc -A \
    -o go-template='"'"'{{range .items}}{{if eq .spec.type "LoadBalancer"}}{{.metadata.namespace}} {{.metadata.name}}{{"\n"}}{{end}}{{end}}'"'"')
  if [ -z "$svcs" ]; then
    echo "No LoadBalancer services found"
  else
    echo "$svcs" | while read -r ns name; do
      echo "Deleting svc/$name in $ns"
      kubectl delete svc "$name" -n "$ns" --ignore-not-found --timeout=60s
    done
  fi'
  aks_invoke "${RG}" "${AKS}" "${LB_CMD}"

  # 2) PVC 삭제 (Azure Disk/File 해제)
  log "  [2/4] Deleting PersistentVolumeClaims..."
  # shellcheck disable=SC2016
  PVC_CMD='for ns in $(kubectl get ns -o jsonpath="{.items[*].metadata.name}"); do
    kubectl delete pvc --all -n "$ns" --ignore-not-found --timeout=120s
  done'
  aks_invoke "${RG}" "${AKS}" "${PVC_CMD}"

  # 3) Flux Extension 제거 (az CLI — 존재하지 않으면 무시)
  log "  [3/4] Removing Flux extension..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY-RUN] az k8s-extension delete -g ${RG} -c ${AKS} --cluster-type managedClusters -n flux --yes"
  else
    az k8s-extension delete \
      -g "${RG}" -c "${AKS}" \
      --cluster-type managedClusters -n flux --yes 2>/dev/null || true
  fi

  # 4) AKS Backup Extension 제거 (az CLI — 존재하지 않으면 무시)
  log "  [4/4] Removing AKS Backup extension..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY-RUN] az k8s-extension delete -g ${RG} -c ${AKS} --cluster-type managedClusters -n azure-aks-backup --yes"
  else
    az k8s-extension delete \
      -g "${RG}" -c "${AKS}" \
      --cluster-type managedClusters -n azure-aks-backup --yes 2>/dev/null || true
  fi

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
      if [[ "${DRY_RUN}" == "true" ]]; then
        log "  [DRY-RUN] az dataprotection backup-instance delete -g ${VAULT_RG} --vault-name ${VAULT_NAME} -n ${instance} --yes"
      else
        az dataprotection backup-instance delete \
          -g "${VAULT_RG}" --vault-name "${VAULT_NAME}" \
          -n "${instance}" --yes 2>/dev/null || \
          log "  [WARN] Backup instance ${instance} 삭제 실패 — 이미 삭제됐거나 Azure API 오류. tofu destroy 계속 진행."
      fi
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
