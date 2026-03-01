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

echo "[tetragon] Installing Cilium Tetragon on: ${CLUSTER}"

TETRAGON_VERSION="1.4.0"
NAMESPACE="kube-system"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
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
  --wait

echo "[tetragon] ✓ Installed Tetragon v${TETRAGON_VERSION} on ${CLUSTER} (DaemonSet, system-node-critical)"
