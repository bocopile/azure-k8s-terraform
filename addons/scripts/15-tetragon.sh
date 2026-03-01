#!/usr/bin/env bash
# ============================================================
# 15-tetragon.sh — Cilium Tetragon (eBPF 런타임 보안 감시)
#
# Managed Cilium eBPF dataplane 위에 Tetragon을 추가하여
# 프로세스 실행, 파일 접근, 네트워크 연결 등을 실시간 추적.
# Falco 대비 장점: 동일 eBPF 기반이라 커널 모듈 이중화 없음.
#
# 대상: 전체 클러스터 (mgmt, app1, app2)
#
# Usage: ./15-tetragon.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[tetragon] Installing Cilium Tetragon on: ${CLUSTER}"

TETRAGON_VERSION="1.4.0"
NAMESPACE="kube-system"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add cilium https://helm.cilium.io --force-update
helm upgrade --install tetragon cilium/tetragon \
  --namespace "${NAMESPACE}" \
  --version "${TETRAGON_VERSION}" \
  --set tetragon.enableProcessCred=true \
  --set tetragon.enableProcessNs=true \
  --set tetragon.grpc.address="localhost:54321" \
  --wait

echo "[tetragon] ✓ Installed Tetragon v${TETRAGON_VERSION} on ${CLUSTER}"
echo "[tetragon] TracingPolicy 예시:"
echo "   kubectl apply -f https://raw.githubusercontent.com/cilium/tetragon/main/examples/quickstart/file_monitoring.yaml"
echo "   kubectl logs -n ${NAMESPACE} ds/tetragon -c export-stdout -f | tetra getevents"
