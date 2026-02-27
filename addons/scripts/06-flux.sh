#!/usr/bin/env bash
# ============================================================
# 06-flux.sh — Enable AKS GitOps Add-on (Flux v2)
#
# Authentication: SSH Deploy Key (K8s Secret)
# ADR-012 / C12: Federated Token not used
#
# Usage: ./06-flux.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[flux] Enabling AKS GitOps (Flux v2) on: ${CLUSTER}"

RG="rg-k8s-demo-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"

# Enable the GitOps extension
az k8s-extension create \
  --resource-group "${RG}" \
  --cluster-name "${CLUSTER_NAME}" \
  --cluster-type managedClusters \
  --extension-type Microsoft.Flux \
  --name flux \
  --scope cluster \
  --auto-upgrade-minor-version true

echo "[flux] ✓ Flux v2 extension enabled on ${CLUSTER}"
echo "[flux] TODO: Create FluxConfig with SSH Deploy Key pointing to your GitOps repo"
echo "[flux] Example:"
echo "   az k8s-configuration flux create --cluster-name ${CLUSTER_NAME} \\"
echo "     --resource-group ${RG} --cluster-type managedClusters \\"
echo "     --name gitops-${CLUSTER} --namespace flux-system \\"
echo "     --url ssh://git@github.com/<org>/<repo>.git \\"
echo "     --branch main --ssh-private-key-file ~/.ssh/flux-deploy-key"
