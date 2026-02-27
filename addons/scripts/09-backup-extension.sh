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

RG="rg-k8s-demo-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"
COMMON_RG="rg-k8s-demo-common"
VAULT_NAME="bv-k8s-demo"
POLICY_NAME="bp-aks-daily"

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
echo "[backup] TODO: Create BackupInstance to associate cluster with Vault"
echo "[backup]   az dataprotection backup-instance create \\"
echo "[backup]     --resource-group ${COMMON_RG} \\"
echo "[backup]     --vault-name ${VAULT_NAME} \\"
echo "[backup]     --backup-instance <backup-instance.json>"
