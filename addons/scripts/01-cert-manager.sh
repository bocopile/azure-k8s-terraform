#!/usr/bin/env bash
# ============================================================
# 01-cert-manager.sh — Install cert-manager v1.19.x on mgmt cluster
#
# HA 설정:
#   - replicas: 2 (HPA min), resources, PDB, TopologySpread
#   - HPA: min 2 / max 4 / CPU 80%
#   - PriorityClass: platform-critical
#
# Usage: ./01-cert-manager.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[cert-manager] Installing on cluster: ${CLUSTER}"

CERT_MANAGER_VERSION="v1.19.0"
NAMESPACE="cert-manager"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set installCRDs=true \
  --set global.leaderElection.namespace="${NAMESPACE}" \
  --set global.priorityClassName=platform-critical \
  --set replicaCount=2 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=128Mi \
  --set podDisruptionBudget.enabled=true \
  --set podDisruptionBudget.minAvailable=1 \
  --set 'topologySpreadConstraints[0].maxSkew=1' \
  --set 'topologySpreadConstraints[0].topologyKey=topology.kubernetes.io/zone' \
  --set 'topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway' \
  --set 'topologySpreadConstraints[0].labelSelector.matchLabels.app\.kubernetes\.io/name=cert-manager' \
  --set webhook.replicaCount=2 \
  --set webhook.resources.requests.cpu=25m \
  --set webhook.resources.requests.memory=32Mi \
  --set webhook.resources.limits.cpu=100m \
  --set webhook.resources.limits.memory=64Mi \
  --set cainjector.resources.requests.cpu=25m \
  --set cainjector.resources.requests.memory=64Mi \
  --set cainjector.resources.limits.cpu=100m \
  --set cainjector.resources.limits.memory=128Mi \
  --wait

# HPA — cert-manager controller
cat <<'EOF' | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cert-manager
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

echo "[cert-manager] ✓ Installed ${CERT_MANAGER_VERSION} on ${CLUSTER} (HA + HPA)"
