#!/usr/bin/env bash
# ============================================================
# 05-kyverno.sh — Install Kyverno (app clusters only)
#
# Kyverno Helm chart v3.7.1 / App v1.16.x
# Enforce mode: applied to app1, app2
# NOT applied to mgmt (ADR-003 / C4)
#
# Usage: ./05-kyverno.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

# Enforce only on app clusters
if [[ "${CLUSTER}" == "mgmt" ]]; then
  echo "[kyverno] Skipping mgmt cluster (ADR-003: Kyverno is app-only)"
  exit 0
fi

echo "[kyverno] Installing Kyverno on: ${CLUSTER}"

KYVERNO_CHART_VERSION="3.7.1"
NAMESPACE="kyverno"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing

helm repo add kyverno https://kyverno.github.io/kyverno --force-update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${KYVERNO_CHART_VERSION}" \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2 \
  --set cleanupController.replicas=2 \
  --set reportsController.replicas=2 \
  --wait

echo "[kyverno] ✓ Installed chart v${KYVERNO_CHART_VERSION} on ${CLUSTER}"
echo "[kyverno] TODO: Apply Pod Security baseline ClusterPolicy"
