#!/usr/bin/env bash
# ============================================================
# 07-kiali.sh — Install Kiali v2.21 on mgmt cluster
#
# Kiali requires Istio to be enabled first (04-istio.sh).
# Applied to mgmt cluster only.
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
  --name "aks-${CLUSTER}" --overwrite-existing

helm repo add kiali https://kiali.org/helm-charts --force-update
helm upgrade --install kiali-operator kiali/kiali-operator \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${KIALI_VERSION}" \
  --wait

echo "[kiali] ✓ Kiali operator v${KIALI_VERSION} installed on ${CLUSTER}"
echo "[kiali] TODO: Apply KialiCR to configure Prometheus/Grafana datasources"
