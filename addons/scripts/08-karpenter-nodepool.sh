#!/usr/bin/env bash
# ============================================================
# 08-karpenter-nodepool.sh — Configure Karpenter/NAP NodePool
#
# NAP is enabled via node_provisioning_profile.mode = "Auto" in Terraform.
# This script applies NodePool CRs to define scaling constraints.
#
# Usage: ./08-karpenter-nodepool.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[karpenter] Configuring NAP NodePool on: ${CLUSTER}"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing

# Apply NodePool CR (example — customize per cluster)
kubectl apply -f - <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-worker
spec:
  template:
    spec:
      requirements:
        - key: karpenter.azure.com/sku-family
          operator: In
          values: ["D"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["koreacentral-1", "koreacentral-2", "koreacentral-3"]
  limits:
    cpu: "20"      # D2s_v5(2vCPU) 기준 약 10노드 상한 (ARCHITECTURE.md §4.3)
    memory: "40Gi" # D2s_v5(8GB) 기준 약 5노드 — 비용 가드레일 (ADR-012/C10)
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
EOF

echo "[karpenter] ✓ NAP NodePool 'spot-worker' applied on ${CLUSTER}"
