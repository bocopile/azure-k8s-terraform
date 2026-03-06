#!/usr/bin/env bash
# ============================================================
# 07-kiali.sh — Install Kiali v2.22 on mgmt cluster
#
# HA 설정:
#   - replicas: 1 (mgmt only, 단일 인스턴스 충분)
#   - resources, PriorityClass: workload-high
#
# Usage: ./07-kiali.sh mgmt
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

if [[ "${CLUSTER}" != "mgmt" ]]; then
  echo "[kiali] Kiali is mgmt-only. Skipping ${CLUSTER}."
  exit 0
fi

echo "[kiali] Installing Kiali v2.22 on: ${CLUSTER}"

KIALI_VERSION="2.22.0"
NAMESPACE="kiali-operator"

az aks get-credentials --resource-group "rg-${PREFIX:-k8s}-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add kiali https://kiali.org/helm-charts --force-update
helm upgrade --install kiali-operator kiali/kiali-operator \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${KIALI_VERSION}" \
  --set priorityClassName=workload-high \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=256Mi \
  --wait --timeout 10m

echo "[kiali] ✓ Kiali operator v${KIALI_VERSION} installed on ${CLUSTER}"

# ---- PROMETHEUS_URL 확인 ----
if [[ -z "${PROMETHEUS_URL:-}" ]]; then
  echo "[kiali][WARN] PROMETHEUS_URL 미설정 — Kiali 메트릭 기능 비활성화됩니다."
  echo "[kiali][WARN] Azure Monitor Workspace DCE 쿼리 엔드포인트를 addon_env.PROMETHEUS_URL 에 설정하세요."
fi

# ---- Kiali CR 생성 ----
# Operator가 준비될 때까지 대기
echo "[kiali] Waiting for kiali-operator to be ready..."
kubectl -n "${NAMESPACE}" wait --for=condition=Available deployment/kiali-operator --timeout=120s

# Kiali CR: Istio + Azure Managed Prometheus 연동
# PROMETHEUS_URL: Azure Monitor Workspace 쿼리 엔드포인트 (선택 — 미설정 시 비활성화)
cat <<EOF | kubectl apply -f -
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
  namespace: "${NAMESPACE}"
spec:
  auth:
    strategy: anonymous
  deployment:
    namespace: istio-system
    accessible_namespaces:
      - "**"
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
    priority_class_name: workload-high
  external_services:
    istio:
      root_namespace: istio-system
    prometheus:
      # Azure Managed Prometheus 쿼리 URL (DCE public endpoint)
      # 미설정 시 Kiali 메트릭 기능 비활성화 — Prometheus 연동 후 업데이트
      url: "${PROMETHEUS_URL:-}"
    grafana:
      enabled: ${GRAFANA_ENABLED:-false}
      url: "${GRAFANA_URL:-}"
  istio_namespace: istio-system
EOF

echo "[kiali] ✓ Kiali CR created — UI: kubectl port-forward svc/kiali -n istio-system 20001:20001"
