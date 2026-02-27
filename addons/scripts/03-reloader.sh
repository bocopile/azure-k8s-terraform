#!/usr/bin/env bash
# ============================================================
# 03-reloader.sh — Install Stakater Reloader
#
# Watches ConfigMap/Secret changes (including KV CSI auto-rotation)
# and triggers rolling restarts on annotated Deployments.
#
# Usage: ./03-reloader.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[reloader] Installing Stakater Reloader on: ${CLUSTER}"

NAMESPACE="reloader"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing

helm repo add stakater https://stakater.github.io/stakater-charts --force-update
helm upgrade --install reloader stakater/reloader \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait

echo "[reloader] ✓ Installed on ${CLUSTER}"
