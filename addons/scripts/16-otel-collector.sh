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

OTEL_CHART_VERSION="0.146.1"
NAMESPACE="otel-system"

az aks get-credentials --resource-group "rg-${PREFIX:-k8s}-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

# App Insights Connection String 가져오기
APPINSIGHTS_CS=$(az monitor app-insights component show \
  --resource-group "rg-${PREFIX:-k8s}-common" \
  --app "appi-${PREFIX:-k8s}" \
  --query "connectionString" --output tsv 2>/dev/null || echo "")

if [[ -z "${APPINSIGHTS_CS}" ]]; then
  echo "[otel] ERROR: App Insights connection string not found." >&2
  echo "[otel] Ensure 'appi-${PREFIX:-k8s}' exists in 'rg-${PREFIX:-k8s}-common'." >&2
  echo "[otel] Or set APPINSIGHTS_CONNECTION_STRING env var before running." >&2
  exit 1
fi

# Namespace 생성
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# App Insights Connection String → Key Vault 저장 후 ExternalSecret으로 동기화
# 전제: 02-external-secrets.sh 실행 완료 + ClusterSecretStore 'azure-keyvault' 존재
KV_SECRET_NAME="otel-appinsights-connection-string"

# Key Vault에 시크릿 저장 (없는 경우에만)
KV_NAME=$(az keyvault list --resource-group "rg-${PREFIX:-k8s}-common" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [[ -n "${KV_NAME}" ]]; then
  if ! az keyvault secret show --vault-name "${KV_NAME}" --name "${KV_SECRET_NAME}" \
      --output none 2>/dev/null; then
    echo "[otel] Key Vault '${KV_NAME}'에 시크릿 저장: ${KV_SECRET_NAME}"
    az keyvault secret set --vault-name "${KV_NAME}" \
      --name "${KV_SECRET_NAME}" \
      --value "${APPINSIGHTS_CS}" --output none
  else
    echo "[otel] Key Vault 시크릿 이미 존재: ${KV_SECRET_NAME}"
  fi

  # ExternalSecret — Key Vault → K8s Secret 동기화
  cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: otel-appinsights
  namespace: ${NAMESPACE}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault
    kind: ClusterSecretStore
  target:
    name: otel-appinsights
    creationPolicy: Owner
  data:
    - secretKey: connection-string
      remoteRef:
        key: ${KV_SECRET_NAME}
EOF
  echo "[otel] ExternalSecret 생성 완료 — Key Vault → otel-appinsights"
  # ExternalSecret 동기화 대기
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready \
    externalsecret/otel-appinsights --timeout=60s 2>/dev/null || \
    echo "[otel][WARN] ExternalSecret 동기화 대기 타임아웃 — 수동 확인 필요"
else
  # Key Vault 없는 경우 fallback: 직접 시크릿 생성
  echo "[otel][WARN] Key Vault 조회 실패 — kubectl secret으로 fallback"
  kubectl create secret generic otel-appinsights \
    --namespace "${NAMESPACE}" \
    --from-literal=connection-string="${APPINSIGHTS_CS}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace "${NAMESPACE}" \
  --version "${OTEL_CHART_VERSION}" \
  --set image.repository=otel/opentelemetry-collector-contrib \
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
  --wait --timeout 10m

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
