#!/usr/bin/env bash
# ============================================================
# 18-kaito.sh — KAITO (Kubernetes AI Toolchain Operator)
#
# AKS에서 LLM/ML 추론 워크로드 배포 자동화:
#   - GPU NodePool 자동 프로비저닝 (NAP/Karpenter 연계)
#   - 모델 프리셋: Phi-3, Llama-3, Mistral, Falcon 등
#   - az aks 확장(Extension)으로 설치
#
# 주의: GPU 쿼터(NC/ND 시리즈) 사전 확인 필요
#   az vm list-usage --location koreacentral -o table | grep -i "NC\|ND"
#
# 대상: GPU 워크로드 클러스터 (app1 또는 app2)
#
# Usage: ./18-kaito.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[kaito] Installing KAITO on: ${CLUSTER}"

RG="rg-k8s-demo-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"

az aks get-credentials --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" --overwrite-existing --only-show-errors

# GPU 쿼터 사전 확인
echo "[kaito] GPU 쿼터 확인 (Korea Central):"
az vm list-usage --location koreacentral -o table 2>/dev/null \
  | grep -iE "NCas|NCs|NDas|NDs" || echo "  (GPU 시리즈 쿼터 없음 — 증설 요청 필요)"

# KAITO AKS Extension 설치
if ! az aks update \
  --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" \
  --enable-ai-toolchain-operator 2>&1; then
  echo "[kaito] ERROR: KAITO 활성화 실패. 확인 사항:" >&2
  echo "  1. az feature register --namespace Microsoft.ContainerService --name AIToolchainOperatorPreview" >&2
  echo "  2. az provider register --namespace Microsoft.ContainerService" >&2
  echo "  3. GPU 쿼터 가용 여부 확인" >&2
  exit 1
fi

echo "[kaito] ✓ KAITO enabled on ${CLUSTER}"
echo ""
echo "[kaito] 모델 배포 예시 (Phi-3-mini):"
echo "   cat <<'YAML' | kubectl apply -f -"
echo "   apiVersion: kaito.sh/v1alpha1"
echo "   kind: Workspace"
echo "   metadata:"
echo "     name: workspace-phi-3-mini"
echo "   spec:"
echo "     resource:"
echo "       instanceType: Standard_NC6s_v3"
echo "       labelSelector:"
echo "         matchLabels:"
echo "           apps: phi-3"
echo "     inference:"
echo "       preset:"
echo "         name: phi-3-mini-128k-instruct"
echo "   YAML"
echo ""
echo "[kaito] GPU 쿼터 부족 시: Azure Portal → 구독 → 사용량 + 할당량 → 증설 요청"
