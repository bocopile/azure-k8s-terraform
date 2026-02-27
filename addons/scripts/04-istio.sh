#!/usr/bin/env bash
# ============================================================
# 04-istio.sh — Enable AKS Istio Add-on (asm-1-28)
#
# Uses Azure CLI to enable the managed Istio add-on.
# Applied to: mgmt, app1 clusters
#
# Usage: ./04-istio.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[istio] Enabling AKS Istio add-on (asm-1-28) on: ${CLUSTER}"

RG="rg-k8s-demo-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"
REVISION="asm-1-28"

# Enable via az aks mesh enable
az aks mesh enable \
  --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" \
  --revision "${REVISION}"

echo "[istio] ✓ Istio ${REVISION} enabled on ${CLUSTER}"
echo "[istio] TODO: Label namespaces with istio.io/rev=${REVISION} for sidecar injection"
