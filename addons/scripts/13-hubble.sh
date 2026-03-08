#!/usr/bin/env bash
# ============================================================
# 13-hubble.sh — Cilium Hubble UI + Relay 활성화
#
# ARCHITECTURE.md §8.1: Cilium Hubble — 네트워크 플로우 관찰성 (무료)
# Managed Cilium은 AKS에 포함되어 있으나 Hubble UI는 수동 활성화 필요.
# 대상: 전체 클러스터 (mgmt, app1, app2)
#
# ⚠️  ACNS 활성화는 Cilium agent DaemonSet 재시작을 유발합니다.
#     install.sh에서 이 스크립트를 가장 먼저 실행하는 이유:
#     ACNS 완료 + Cilium DaemonSet 안정화 후 다른 addon을 설치해야
#     CNI 중단으로 인한 ContainerCreating/Pending 장애를 방지할 수 있습니다.
#
# Usage: ./13-hubble.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[hubble] Enabling Cilium Hubble on: ${CLUSTER}"

RG="rg-${PREFIX:-k8s}-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"

az aks get-credentials --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" --overwrite-existing --only-show-errors

# ── Cilium DaemonSet 완전 준비 대기 (함수로 분리) ───────────────
wait_cilium_ready() {
  echo "[hubble] Waiting for Cilium DaemonSet to be fully ready on ${CLUSTER}..."
  # Cilium DaemonSet 존재까지 대기 (ACNS 활성화 직후 잠시 없을 수 있음)
  for i in $(seq 1 20); do
    if kubectl get ds cilium -n kube-system &>/dev/null 2>&1; then
      break
    fi
    echo "[hubble]   Cilium DaemonSet not found yet — retrying in 15s (${i}/20)..."
    sleep 15
  done

  kubectl rollout status daemonset/cilium -n kube-system --timeout=10m
  echo "[hubble] ✓ Cilium DaemonSet ready"

  # CNS (Container Network Service)가 모든 노드에서 IP 할당 가능한 상태가 될 때까지 대기
  echo "[hubble] Waiting 30s for CNS to stabilize on all nodes..."
  sleep 30
}

# ── 멱등성 확인: ACNS 이미 활성화된 경우 Cilium 상태만 확인 ────
ACNS_ENABLED=$(az aks show \
  --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" \
  --query 'networkProfile.advancedNetworking.observability.enabled' \
  -o tsv 2>/dev/null || echo "false")

if [[ "${ACNS_ENABLED}" == "true" ]]; then
  echo "[hubble] ✓ ACNS already enabled on ${CLUSTER} — verifying Cilium readiness"
  wait_cilium_ready
  exit 0
fi

# ── ACNS 활성화 ─────────────────────────────────────────────────
# az aks update은 기본적으로 완료될 때까지 블로킹하지만,
# AKS Succeeded 후에도 Cilium DaemonSet 롤아웃이 진행 중일 수 있으므로
# 반드시 rollout status로 추가 확인해야 합니다.
echo "[hubble] Running 'az aks update --enable-acns' (Cilium will restart after this)..."
az aks update \
  --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" \
  --enable-acns

# kubeconfig 재취득 (업데이트 후 endpoint 재확인)
az aks get-credentials --resource-group "${RG}" \
  --name "${CLUSTER_NAME}" --overwrite-existing --only-show-errors

# ── Cilium DaemonSet 완전 준비 대기 ─────────────────────────────
wait_cilium_ready

echo "[hubble] ✓ Hubble (ACNS) enabled on ${CLUSTER}"
echo "[hubble] Hubble UI 접근 방법 (Jump VM에서):"
echo "   kubectl port-forward -n kube-system svc/hubble-ui 12000:80 &"
echo "   # SSH Tunnel: ssh -L 12000:localhost:12000 azureadmin@<jumpbox-ip>"
echo "   # 브라우저: http://localhost:12000"
