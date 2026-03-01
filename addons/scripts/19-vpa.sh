#!/usr/bin/env bash
# ============================================================
# 19-vpa.sh — Vertical Pod Autoscaler (Pod 리소스 수직 최적화)
#
# HA 설정:
#   - replicas: 1 (recommend-only, 단일 인스턴스 충분)
#   - resources, PriorityClass: platform-critical
#
# Usage: ./19-vpa.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[vpa] Installing Vertical Pod Autoscaler on: ${CLUSTER}"

VPA_VERSION="4.7.1"
NAMESPACE="kube-system"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add fairwinds-stable https://charts.fairwinds.com/stable --force-update
helm upgrade --install vpa fairwinds-stable/vpa \
  --namespace "${NAMESPACE}" \
  --version "${VPA_VERSION}" \
  --set recommender.enabled=true \
  --set updater.enabled=false \
  --set admissionController.enabled=false \
  --set recommender.priorityClassName=platform-critical \
  --set recommender.resources.requests.cpu=25m \
  --set recommender.resources.requests.memory=32Mi \
  --set recommender.resources.limits.cpu=200m \
  --set recommender.resources.limits.memory=128Mi \
  --wait

echo "[vpa] ✓ Installed VPA v${VPA_VERSION} on ${CLUSTER} (recommend-only)"
