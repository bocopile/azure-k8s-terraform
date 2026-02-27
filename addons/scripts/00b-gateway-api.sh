#!/usr/bin/env bash
# ============================================================
# 00b-gateway-api.sh — Gateway API CRD 설치
#
# ARCHITECTURE.md §5.3: Istio GA 전환 대비 CRD 사전 배포
# 현재: Istio classic API 사용, Gateway API CRD만 설치 (리소스 미사용)
#
# CRD 버전: v1.3.0
# 설치 대상: 전체 클러스터 (mgmt, app1, app2)
#
# Usage: ./00b-gateway-api.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

GATEWAY_API_VERSION="v1.3.0"

echo "[gateway-api] Installing Gateway API CRDs (${GATEWAY_API_VERSION}) on: ${CLUSTER}"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

# Standard channel CRDs (HTTPRoute, GRPCRoute, Gateway, GatewayClass 포함)
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "[gateway-api] ✓ Gateway API ${GATEWAY_API_VERSION} CRDs installed on ${CLUSTER}"
echo "[gateway-api] NOTE: 실제 Gateway/HTTPRoute 리소스는 Istio GA 전환 후 사용"
echo "[gateway-api]       현재는 Istio classic (Gateway + VirtualService) 사용 중"
