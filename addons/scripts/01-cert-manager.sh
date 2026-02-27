#!/usr/bin/env bash
# ============================================================
# 01-cert-manager.sh — Install cert-manager v1.19.x on mgmt cluster
#
# Components:
#   - cert-manager Helm chart (jetstack/cert-manager)
#   - ClusterIssuer: Let's Encrypt (DNS-01 / Azure DNS)
#   - Workload Identity annotation on cert-manager SA
#
# Usage: ./01-cert-manager.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[cert-manager] Installing on cluster: ${CLUSTER}"

CERT_MANAGER_VERSION="v1.19.0"
NAMESPACE="cert-manager"

# Switch kubectl context
az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing

# Install cert-manager via Helm
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set installCRDs=true \
  --set global.leaderElection.namespace="${NAMESPACE}" \
  --wait

echo "[cert-manager] ✓ Installed ${CERT_MANAGER_VERSION} on ${CLUSTER}"
echo "[cert-manager] TODO: Apply ClusterIssuer manifest (ACME / DNS-01)"
