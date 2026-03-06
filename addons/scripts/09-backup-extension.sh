#!/usr/bin/env bash
# ============================================================
# 09-backup-extension.sh — AKS Backup 상태 확인 (참고용)
#
# AKS Backup Extension, BackupInstance, RBAC는 모두 Terraform으로 관리됩니다.
#   - modules/backup/main.tf:
#     azurerm_kubernetes_cluster_extension.backup
#     azurerm_data_protection_backup_instance_kubernetes_cluster.aks
#     azurerm_role_assignment.vault_cluster_rg_contributor
#     azurerm_role_assignment.kubelet_snapshot_contributor
#
# 이 스크립트는 배포 후 상태 확인 용도로만 사용합니다.
#
# Usage: ./09-backup-extension.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[backup] Checking AKS Backup Extension status on: ${CLUSTER}"

RG="rg-${PREFIX:-k8s}-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"
COMMON_RG="rg-${PREFIX:-k8s}-common"
VAULT_NAME="bv-${PREFIX:-k8s}"

# Extension 상태 확인 (Terraform apply 완료 후)
PROV_STATE=$(az k8s-extension show \
  --resource-group "${RG}" \
  --cluster-name "${CLUSTER_NAME}" \
  --cluster-type managedClusters \
  --name azure-aks-backup \
  --query "provisioningState" --output tsv 2>/dev/null || echo "NotFound")

echo "[backup] Extension provisioning state: ${PROV_STATE}"

if [[ "${PROV_STATE}" == "Succeeded" ]]; then
  echo "[backup] ✓ AKS Backup Extension is ready on ${CLUSTER}"
else
  echo "[backup] Extension not ready. Terraform apply가 완료되었는지 확인하세요."
  echo "[backup]   tofu apply -target=module.backup"
fi

# BackupInstance 상태 확인
echo "[backup] BackupInstance list in vault: ${VAULT_NAME}"
az dataprotection backup-instance list \
  --resource-group "${COMMON_RG}" \
  --vault-name "${VAULT_NAME}" \
  --query "[?contains(name, '${CLUSTER}')].{Name:name, State:properties.currentProtectionState}" \
  --output table 2>/dev/null || echo "[backup] BackupInstance 조회 실패 — vault 존재 여부 확인"
