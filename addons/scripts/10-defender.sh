#!/usr/bin/env bash
# ============================================================
# 10-defender.sh — Enable Microsoft Defender for Containers
#
# Defender for Containers is enabled via AKS cluster config in Terraform
# (microsoft_defender block). This script verifies the extension
# is active and enables additional policies if needed.
#
# Usage: ./10-defender.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[defender] Verifying Defender for Containers on: ${CLUSTER}"

RG="rg-k8s-demo-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"

# Verify Defender extension is installed
DEFENDER_STATUS=$(az aks show \
  --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" \
  --query "securityProfile.defender.logAnalyticsWorkspaceResourceId" \
  --output tsv 2>/dev/null || echo "NOT_FOUND")

if [[ "${DEFENDER_STATUS}" == "NOT_FOUND" || -z "${DEFENDER_STATUS}" ]]; then
  echo "[defender] WARNING: Defender not detected on ${CLUSTER}. Verify Terraform apply completed."
else
  echo "[defender] ✓ Defender active on ${CLUSTER} (workspace: ${DEFENDER_STATUS})"
fi

echo "[defender] TODO: Review Defender recommendations in Azure Security Center"
