#!/usr/bin/env bash
# ============================================================
# 02-external-secrets.sh — Install External Secrets Operator
#
# ESO PushSecret: cert-manager issued certs → Key Vault sync
# Prevents private keys from living in etcd long-term.
#
# Usage: ./02-external-secrets.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[eso] Installing External Secrets Operator on: ${CLUSTER}"

ESO_VERSION="0.10.5"
NAMESPACE="external-secrets"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing

helm repo add external-secrets https://charts.external-secrets.io --force-update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${ESO_VERSION}" \
  --wait

echo "[eso] ✓ Installed v${ESO_VERSION} on ${CLUSTER}"
echo "[eso] TODO: Apply SecretStore / ClusterSecretStore with AzureKeyVault backend"
