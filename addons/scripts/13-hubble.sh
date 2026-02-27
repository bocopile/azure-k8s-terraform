#!/usr/bin/env bash
# ============================================================
# 13-hubble.sh — Cilium Hubble UI + Relay 활성화
#
# ARCHITECTURE.md §8.1: Cilium Hubble — 네트워크 플로우 관찰성 (무료)
# Managed Cilium은 AKS에 포함되어 있으나 Hubble UI는 수동 활성화 필요.
# 대상: 전체 클러스터 (mgmt, app1, app2)
#
# Usage: ./13-hubble.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[hubble] Enabling Cilium Hubble on: ${CLUSTER}"

RG="rg-k8s-demo-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"

az aks get-credentials --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" --overwrite-existing --only-show-errors

# AKS Managed Cilium에서 Hubble 활성화
az aks update \
  --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" \
  --enable-cilium-observability

echo "[hubble] ✓ Hubble enabled on ${CLUSTER}"
echo "[hubble] Hubble UI 접근 방법 (Jump VM에서):"
echo "   kubectl port-forward -n kube-system svc/hubble-ui 12000:80 &"
echo "   # SSH Tunnel: ssh -L 12000:localhost:12000 azureadmin@<jumpbox-ip>"
echo "   # 브라우저: http://localhost:12000"
