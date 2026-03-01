#!/usr/bin/env bash
# ============================================================
# 19-vpa.sh — Vertical Pod Autoscaler (Pod 리소스 수직 최적화)
#
# NAP/Karpenter가 노드 수평 확장을 담당하고,
# VPA는 개별 Pod의 CPU/Memory request/limit을 자동 조정.
# AI 추론 Pod처럼 리소스 변동이 큰 워크로드에 유용.
#
# 모드: recommend-only (기본) — UpdateMode: "Off"로 시작 후
#       안정화되면 "Auto"로 전환 권장
#
# 대상: 전체 클러스터 (mgmt, app1, app2)
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
  --wait

echo "[vpa] ✓ Installed VPA v${VPA_VERSION} on ${CLUSTER} (recommend-only mode)"
echo "[vpa] VPA 적용 예시:"
echo "   cat <<'YAML' | kubectl apply -f -"
echo "   apiVersion: autoscaling.k8s.io/v1"
echo "   kind: VerticalPodAutoscaler"
echo "   metadata:"
echo "     name: my-app-vpa"
echo "   spec:"
echo "     targetRef:"
echo "       apiVersion: apps/v1"
echo "       kind: Deployment"
echo "       name: my-app"
echo "     updatePolicy:"
echo "       updateMode: \"Off\"   # Off=추천만, Auto=자동 조정"
echo "   YAML"
echo ""
echo "[vpa] 추천 확인: kubectl describe vpa my-app-vpa"
