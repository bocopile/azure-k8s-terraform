#!/usr/bin/env bash
# ============================================================
# 17-trivy-operator.sh — Trivy Operator (클러스터 내 보안 스캔)
#
# 이미지 취약점 + ConfigAudit + RBAC Assessment를 지속 스캔.
# Defender for Containers(Azure 네이티브)와 보완 관계:
#   Defender = 클라우드 레벨 + 빌드 시 스캔
#   Trivy    = 클러스터 내 런타임 이미지 스캔 + CIS Benchmark
#
# 대상: 전체 클러스터 (mgmt, app1, app2)
#
# Usage: ./17-trivy-operator.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[trivy] Installing Trivy Operator on: ${CLUSTER}"

TRIVY_VERSION="0.28.1"
NAMESPACE="trivy-system"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add aquasecurity https://aquasecurity.github.io/helm-charts --force-update
helm upgrade --install trivy-operator aquasecurity/trivy-operator \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${TRIVY_VERSION}" \
  --set operator.scanJobsConcurrentLimit=3 \
  --set operator.vulnerabilityScannerScanOnlyCurrentRevisions=true \
  --set operator.configAuditScannerEnabled=true \
  --set operator.rbacAssessmentScannerEnabled=true \
  --set operator.infraAssessmentScannerEnabled=true \
  --set trivyOperator.scanJobCompressLogs=true \
  --set trivy.severity="CRITICAL,HIGH" \
  --wait

echo "[trivy] ✓ Installed Trivy Operator v${TRIVY_VERSION} on ${CLUSTER}"
echo "[trivy] 취약점 리포트 확인:"
echo "   kubectl get vulnerabilityreports -A -o wide"
echo "   kubectl get configauditreports -A -o wide"
echo "   kubectl get rbacassessmentreports -A -o wide"
