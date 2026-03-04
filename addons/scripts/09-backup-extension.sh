#!/usr/bin/env bash
# ============================================================
# 09-backup-extension.sh — Install AKS Backup Extension
#
# The Backup Vault is created by Terraform (modules/backup/).
# This script installs the AKS Backup Extension on each cluster
# and creates a BackupInstance.
#
# Usage: ./09-backup-extension.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[backup] Installing AKS Backup Extension on: ${CLUSTER}"

RG="rg-${PREFIX:-k8s}-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"
COMMON_RG="rg-${PREFIX:-k8s}-common"
VAULT_NAME="bv-${PREFIX:-k8s}"
# Install AKS Backup Extension
az k8s-extension create \
  --resource-group "${RG}" \
  --cluster-name "${CLUSTER_NAME}" \
  --cluster-type managedClusters \
  --extension-type Microsoft.DataProtection.Kubernetes \
  --name azure-aks-backup \
  --release-train stable \
  --auto-upgrade-minor-version true

echo "[backup] ✓ AKS Backup Extension installed on ${CLUSTER}"

# Wait for extension to be ready
echo "[backup] Waiting for extension to be ready..."
az k8s-extension show \
  --resource-group "${RG}" \
  --cluster-name "${CLUSTER_NAME}" \
  --cluster-type managedClusters \
  --name azure-aks-backup \
  --query "provisioningState" --output tsv

echo "[backup] NOTE: BackupInstance creation requires manual configuration."
echo "[backup] See: az dataprotection backup-instance create"
echo "[backup]   --resource-group ${COMMON_RG}"
echo "[backup]   --vault-name ${VAULT_NAME}"
