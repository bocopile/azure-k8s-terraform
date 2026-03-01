#!/usr/bin/env bash
# ============================================================
# 02-external-secrets.sh — Install External Secrets Operator
#
# HA 설정:
#   - replicas: 2 (HPA min), resources, PDB, TopologySpread
#   - HPA: min 2 / max 4 / CPU 80%
#   - PriorityClass: platform-critical
#
# Usage: ./02-external-secrets.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[eso] Installing External Secrets Operator on: ${CLUSTER}"

ESO_VERSION="0.10.5"
NAMESPACE="external-secrets"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add external-secrets https://charts.external-secrets.io --force-update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${ESO_VERSION}" \
  --set replicaCount=2 \
  --set priorityClassName=platform-critical \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=128Mi \
  --set podDisruptionBudget.enabled=true \
  --set podDisruptionBudget.minAvailable=1 \
  --set 'topologySpreadConstraints[0].maxSkew=1' \
  --set 'topologySpreadConstraints[0].topologyKey=topology.kubernetes.io/zone' \
  --set 'topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway' \
  --set 'topologySpreadConstraints[0].labelSelector.matchLabels.app\.kubernetes\.io/name=external-secrets' \
  --set webhook.replicaCount=2 \
  --set webhook.resources.requests.cpu=25m \
  --set webhook.resources.requests.memory=32Mi \
  --set webhook.resources.limits.cpu=100m \
  --set webhook.resources.limits.memory=64Mi \
  --set certController.resources.requests.cpu=25m \
  --set certController.resources.requests.memory=64Mi \
  --set certController.resources.limits.cpu=100m \
  --set certController.resources.limits.memory=128Mi \
  --wait

# HPA — ESO controller
cat <<'EOF' | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: external-secrets
  namespace: external-secrets
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: external-secrets
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 80
EOF

echo "[eso] ✓ Installed v${ESO_VERSION} on ${CLUSTER} (HA + HPA)"
