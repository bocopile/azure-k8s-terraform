#!/usr/bin/env bash
# ============================================================
# 16-otel-collector.sh — OpenTelemetry Collector (분산 트레이싱)
#
# HA 설정:
#   - replicas: 2 (HPA min), resources, PDB, TopologySpread
#   - HPA: min 2 / max 5 / CPU 70%
#   - PriorityClass: platform-critical
#
# Usage: ./16-otel-collector.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[otel] Installing OpenTelemetry Collector on: ${CLUSTER}"

OTEL_CHART_VERSION="0.116.0"
NAMESPACE="otel-system"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

# App Insights Connection String 가져오기
APPINSIGHTS_CS=$(az monitor app-insights component show \
  --resource-group "rg-k8s-demo-common" \
  --app "appi-k8s-demo" \
  --query "connectionString" --output tsv 2>/dev/null || echo "")

if [[ -z "${APPINSIGHTS_CS}" ]]; then
  echo "[otel] WARNING: App Insights connection string not found."
  echo "[otel] Set APPINSIGHTS_CONNECTION_STRING manually in the Secret."
  APPINSIGHTS_CS="PLACEHOLDER"
fi

# Namespace + Secret 생성
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic otel-appinsights \
  --namespace "${NAMESPACE}" \
  --from-literal=connection-string="${APPINSIGHTS_CS}" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace "${NAMESPACE}" \
  --version "${OTEL_CHART_VERSION}" \
  --set mode=deployment \
  --set replicaCount=2 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=256Mi \
  --set priorityClassName=platform-critical \
  --set 'topologySpreadConstraints[0].maxSkew=1' \
  --set 'topologySpreadConstraints[0].topologyKey=topology.kubernetes.io/zone' \
  --set 'topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway' \
  --set 'topologySpreadConstraints[0].labelSelector.matchLabels.app\.kubernetes\.io/name=opentelemetry-collector' \
  --set 'config.exporters.azuremonitor.connection_string=${env:APPINSIGHTS_CONNECTION_STRING}' \
  --set config.receivers.otlp.protocols.grpc.endpoint="0.0.0.0:4317" \
  --set config.receivers.otlp.protocols.http.endpoint="0.0.0.0:4318" \
  --set "config.service.pipelines.traces.receivers={otlp}" \
  --set "config.service.pipelines.traces.exporters={azuremonitor}" \
  --set "extraEnvs[0].name=APPINSIGHTS_CONNECTION_STRING" \
  --set "extraEnvs[0].valueFrom.secretKeyRef.name=otel-appinsights" \
  --set "extraEnvs[0].valueFrom.secretKeyRef.key=connection-string" \
  --wait

# PDB
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: otel-collector
  namespace: ${NAMESPACE}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: opentelemetry-collector
EOF

# HPA
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: otel-collector
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: otel-collector-opentelemetry-collector
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
EOF

echo "[otel] ✓ Installed OTel Collector v${OTEL_CHART_VERSION} on ${CLUSTER} (HA + HPA)"
