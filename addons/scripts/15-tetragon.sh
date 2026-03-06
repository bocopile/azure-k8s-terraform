#!/usr/bin/env bash
# ============================================================
# 15-tetragon.sh — Cilium Tetragon (eBPF 런타임 보안 감시)
#
# HA 설정:
#   - DaemonSet (노드당 1개, HPA 불필요)
#   - resources, PriorityClass: system-node-critical
#
# Usage: ./15-tetragon.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

# ── Managed Cilium 호환성 체크 ──────────────────────────────────
# AKS Managed Cilium 환경에서 standalone Tetragon 설치 시 eBPF 프로그램 충돌 가능성
RG="rg-${PREFIX:-k8s}-${CLUSTER}"
NETWORK_PLUGIN=$(az aks show -g "${RG}" -n "aks-${CLUSTER}" \
  --query 'networkProfile.networkDataplane' -o tsv 2>/dev/null || echo "")

if [[ "${NETWORK_PLUGIN}" == "cilium" ]]; then
  echo "[tetragon][WARN] AKS Managed Cilium(네트워크 데이터플레인) 감지됨."
  echo "[tetragon][WARN] Standalone Tetragon은 eBPF 프로그램 충돌 가능성이 있습니다."
  echo "[tetragon][WARN] AKS native Tetragon 지원 여부를 먼저 확인하세요:"
  echo "[tetragon][WARN]   az aks show -g ${RG} -n aks-${CLUSTER} --query 'securityProfile'"
  echo "[tetragon][WARN] 계속 설치하려면 TETRAGON_FORCE=true 환경변수를 설정하세요."
  if [[ "${TETRAGON_FORCE:-false}" != "true" ]]; then
    echo "[tetragon] 설치 중단. TETRAGON_FORCE=true 로 강제 설치 가능."
    exit 0
  fi
  echo "[tetragon][WARN] TETRAGON_FORCE=true — 강제 설치 진행."
fi

echo "[tetragon] Installing Cilium Tetragon on: ${CLUSTER}"

TETRAGON_VERSION="1.6.0"
NAMESPACE="kube-system"

az aks get-credentials --resource-group "rg-${PREFIX:-k8s}-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add cilium https://helm.cilium.io --force-update
helm upgrade --install tetragon cilium/tetragon \
  --namespace "${NAMESPACE}" \
  --version "${TETRAGON_VERSION}" \
  --set tetragon.enableProcessCred=true \
  --set tetragon.enableProcessNs=true \
  --set tetragon.grpc.address="localhost:54321" \
  --set tetragon.priorityClassName=system-node-critical \
  --set tetragon.resources.requests.cpu=50m \
  --set tetragon.resources.requests.memory=64Mi \
  --set tetragon.resources.limits.cpu=200m \
  --set tetragon.resources.limits.memory=256Mi \
  --wait --timeout 10m

echo "[tetragon] ✓ Installed Tetragon v${TETRAGON_VERSION} on ${CLUSTER} (DaemonSet, system-node-critical)"
