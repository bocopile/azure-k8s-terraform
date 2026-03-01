#!/usr/bin/env bash
# ============================================================
# 03-reloader.sh — Install Stakater Reloader
#
# HA 설정:
#   - replicas: 2 (HPA min), resources, PDB
#   - HPA: min 2 / max 3 / CPU 80%
#   - PriorityClass: platform-critical
#
# Usage: ./03-reloader.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[reloader] Installing Stakater Reloader on: ${CLUSTER}"

RELOADER_VERSION="1.2.0"
NAMESPACE="reloader"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add stakater https://stakater.github.io/stakater-charts --force-update
helm upgrade --install reloader stakater/reloader \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${RELOADER_VERSION}" \
  --set reloader.deployment.replicas=2 \
  --set reloader.deployment.priorityClassName=platform-critical \
  --set reloader.deployment.resources.requests.cpu=25m \
  --set reloader.deployment.resources.requests.memory=32Mi \
  --set reloader.deployment.resources.limits.cpu=100m \
  --set reloader.deployment.resources.limits.memory=64Mi \
  --wait

# PDB
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: reloader
  namespace: ${NAMESPACE}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: reloader-reloader
EOF

# HPA
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: reloader
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: reloader-reloader
  minReplicas: 2
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 80
EOF

echo "[reloader] ✓ Installed on ${CLUSTER} (HA + HPA)"
