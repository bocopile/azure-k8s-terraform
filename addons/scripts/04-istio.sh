#!/usr/bin/env bash
# ============================================================
# 04-istio.sh — Enable AKS Istio Add-on (asm-1-28)
#
# Uses Azure CLI to enable the managed Istio add-on.
# Applied to: mgmt, app1 clusters
#
# Usage: ./04-istio.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

RG="rg-${PREFIX:-k8s}-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"
REVISION="asm-1-28"

# ── 멱등성 확인: 이미 해당 revision이 활성화된 경우 건너뜀 ──────
CURRENT_REVISION=$(az aks show \
  --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" \
  --query 'serviceMeshProfile.istio.revisions[0]' \
  -o tsv 2>/dev/null || echo "")

if [[ "${CURRENT_REVISION}" == "${REVISION}" ]]; then
  echo "[istio] ✓ Istio ${REVISION} already enabled on ${CLUSTER} — skip"
  exit 0
fi

echo "[istio] Enabling AKS Istio add-on (${REVISION}) on: ${CLUSTER}"

az aks mesh enable \
  --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" \
  --revision "${REVISION}"

# az aks mesh enable은 기본 블로킹이지만, istiod Pod가 완전히 Ready될 때까지 추가 대기
# 04b-istio-mtls.sh가 곧바로 실행되므로 istiod 미준비 시 webhook 오류 발생 가능
echo "[istio] Waiting for istiod to be ready..."
kubectl rollout status deployment/istiod-"${REVISION}" \
  -n aks-istio-system --timeout=10m 2>/dev/null || \
  kubectl rollout status deployment/istiod \
    -n aks-istio-system --timeout=10m

echo "[istio] ✓ Istio ${REVISION} enabled on ${CLUSTER}"
