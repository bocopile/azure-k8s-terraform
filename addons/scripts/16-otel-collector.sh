#!/usr/bin/env bash
# ============================================================
# 16-otel-collector.sh — OpenTelemetry Collector (분산 트레이싱)
#
# Istio span + 앱 trace → Azure Application Insights로 전달.
# Managed Prometheus(Metrics) + Container Insights(Logs) +
# OTel Collector(Traces) → E2E Observability 삼각형 완성.
#
# App Insights Connection String은 Terraform output에서 가져옴.
#
# 대상: 전체 클러스터 (mgmt, app1, app2)
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
  --set 'config.exporters.azuremonitor.connection_string=${env:APPINSIGHTS_CONNECTION_STRING}' \
  --set config.receivers.otlp.protocols.grpc.endpoint="0.0.0.0:4317" \
  --set config.receivers.otlp.protocols.http.endpoint="0.0.0.0:4318" \
  --set "config.service.pipelines.traces.receivers={otlp}" \
  --set "config.service.pipelines.traces.exporters={azuremonitor}" \
  --set "extraEnvs[0].name=APPINSIGHTS_CONNECTION_STRING" \
  --set "extraEnvs[0].valueFrom.secretKeyRef.name=otel-appinsights" \
  --set "extraEnvs[0].valueFrom.secretKeyRef.key=connection-string" \
  --wait

echo "[otel] ✓ Installed OTel Collector v${OTEL_CHART_VERSION} on ${CLUSTER}"
echo "[otel] TODO: Istio mesh config에 extensionProviders로 OTel 등록"
echo "   meshConfig.extensionProviders:"
echo "     - name: otel-tracing"
echo "       opentelemetry:"
echo "         service: otel-collector.${NAMESPACE}.svc.cluster.local"
echo "         port: 4317"
