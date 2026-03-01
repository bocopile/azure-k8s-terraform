#!/usr/bin/env bash
# ============================================================
# 07-kiali.sh — Install Kiali v2.21 on mgmt cluster
#
# HA 설정:
#   - replicas: 1 (mgmt only, 단일 인스턴스 충분)
#   - resources, PriorityClass: workload-high
#
# Usage: ./07-kiali.sh mgmt
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

if [[ "${CLUSTER}" != "mgmt" ]]; then
  echo "[kiali] Kiali is mgmt-only. Skipping ${CLUSTER}."
  exit 0
fi

echo "[kiali] Installing Kiali v2.21 on: ${CLUSTER}"

KIALI_VERSION="2.21.0"
NAMESPACE="kiali-operator"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add kiali https://kiali.org/helm-charts --force-update
helm upgrade --install kiali-operator kiali/kiali-operator \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${KIALI_VERSION}" \
  --set priorityClassName=workload-high \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=256Mi \
  --wait

echo "[kiali] ✓ Kiali operator v${KIALI_VERSION} installed on ${CLUSTER}"
