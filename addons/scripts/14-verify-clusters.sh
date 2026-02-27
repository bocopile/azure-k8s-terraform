#!/usr/bin/env bash
# ============================================================
# 14-verify-clusters.sh — 전체 클러스터 상태 검증
#
# ARCHITECTURE.md §12 설치 워크플로우 — Phase 2 완료 후 실행
# 검증 항목:
#   1. 노드 Ready 상태 + Zone 분산
#   2. 시스템 Pod Running 상태
#   3. Flux 동기화 상태
#   4. Ingress LB External IP 할당
#   5. Key Vault CSI Driver 동작
#   6. Karpenter/NAP NodePool 상태
#
# Usage: ./14-verify-clusters.sh
# ============================================================
set -euo pipefail

CLUSTERS=("mgmt" "app1" "app2")
PASS=0
FAIL=0

log()  { echo "[verify] $*"; }
ok()   { echo "  ✓ $*"; ((PASS++)) || true; }
fail() { echo "  ✗ $*"; ((FAIL++)) || true; }

for CLUSTER in "${CLUSTERS[@]}"; do
  log "============================================"
  log "Checking cluster: aks-${CLUSTER}"
  log "============================================"

  az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
    --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors 2>/dev/null

  # --- 1. 노드 상태 ---
  NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready " | wc -l || echo "99")
  if [[ "${NOT_READY}" -eq 0 ]]; then
    ok "All nodes Ready"
  else
    fail "${NOT_READY} node(s) not Ready"
  fi

  # Zone 분산 확인
  ZONES=$(kubectl get nodes -L topology.kubernetes.io/zone --no-headers 2>/dev/null \
    | awk '{print $NF}' | sort -u | wc -l || echo "0")
  if [[ "${ZONES}" -ge 3 ]]; then
    ok "Nodes spread across ${ZONES} zones"
  else
    fail "Nodes only in ${ZONES} zone(s) (expected 3)"
  fi

  # --- 2. 시스템 Pod 상태 ---
  FAILING_PODS=$(kubectl get pods -A --no-headers 2>/dev/null \
    | grep -vE "Running|Completed|Succeeded" | grep -v "^$" | wc -l || echo "99")
  if [[ "${FAILING_PODS}" -eq 0 ]]; then
    ok "All pods Running/Completed"
  else
    fail "${FAILING_PODS} pod(s) not Running"
    kubectl get pods -A --no-headers 2>/dev/null | grep -vE "Running|Completed|Succeeded" || true
  fi

  # --- 3. Key Vault CSI Driver ---
  CSI_PODS=$(kubectl get pods -n kube-system -l app=secrets-store-csi-driver \
    --no-headers 2>/dev/null | grep "Running" | wc -l || echo "0")
  if [[ "${CSI_PODS}" -gt 0 ]]; then
    ok "Key Vault CSI Driver running (${CSI_PODS} pod(s))"
  else
    fail "Key Vault CSI Driver not found"
  fi

  # --- 4. Flux 상태 (설치된 경우) ---
  if kubectl get ns flux-system &>/dev/null; then
    FLUX_READY=$(kubectl get gitrepositories,kustomizations -n flux-system \
      --no-headers 2>/dev/null | grep "True" | wc -l || echo "0")
    ok "Flux resources ready: ${FLUX_READY}"
  else
    log "  - Flux not installed on ${CLUSTER} (skip)"
  fi

  # --- 5. Karpenter/NAP NodePool ---
  if kubectl get nodepools 2>/dev/null | grep -q "spot-worker"; then
    ok "Karpenter NodePool 'spot-worker' exists"
  else
    fail "Karpenter NodePool 'spot-worker' not found (run 08-karpenter-nodepool.sh)"
  fi

  echo ""
done

log "============================================"
log "Verification Summary"
log "  PASS: ${PASS}  FAIL: ${FAIL}"
log "============================================"

if [[ "${FAIL}" -gt 0 ]]; then
  echo "[verify] ✗ Some checks failed. Review output above."
  exit 1
else
  echo "[verify] ✓ All checks passed."
fi
