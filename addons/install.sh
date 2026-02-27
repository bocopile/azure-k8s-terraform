#!/usr/bin/env bash
# ============================================================
# addons/install.sh — Phase 2: Addon Installation Entry Point
# Run AFTER `tofu apply` completes successfully.
#
# 실행 순서 (ARCHITECTURE.md §12 설치 워크플로우):
#   00  priority-classes  — 스케줄링 우선순위 사전 정의
#   00b gateway-api       — Gateway API CRD (Istio GA 대비)
#   01  cert-manager      — TLS 인증서 관리 (mgmt only)
#   02  external-secrets  — ESO PushSecret (전체)
#   03  reloader          — Key Vault Auto-rotation 연동 (전체)
#   04  istio             — AKS Istio asm-1-28 (mgmt, app1)
#   05  kyverno           — 정책 엔진 (app1, app2 only)
#   06  flux              — GitOps Flux v2 (전체)
#   07  kiali             — 서비스 메시 관찰성 (mgmt only)
#   08  karpenter-nodepool— Karpenter NodePool CRD (전체)
#   09  backup-extension  — AKS Backup Extension (전체)
#   10  defender          — Defender for Containers 검증 (전체)
#   11  budget-alert      — $250/월 예산 알림
#   12  aks-automation    — AKS Stop/Start 자동화
#   13  hubble            — Cilium Hubble UI (전체)
#   14  verify-clusters   — 최종 검증
#
# Usage:
#   chmod +x addons/install.sh
#   ./addons/install.sh [--cluster mgmt|app1|app2|all] [--dry-run]
#
# Prerequisites (Jump VM 또는 VPN 접속 환경):
#   - kubectl, helm, az, kubelogin 설치됨
#   - az login 완료
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# --- Parse arguments ---
CLUSTER_TARGET="all"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      CLUSTER_TARGET="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# ============================================================
# Phase 2 Installation
# ============================================================

log "=== Phase 2: Addon Installation ==="
log "Target cluster: ${CLUSTER_TARGET}"
log "Dry run: ${DRY_RUN}"
echo ""

# --- Step 00: PriorityClass (전체 — 가장 먼저) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [00] Installing PriorityClasses on ${cluster} ---"
    run "${SCRIPTS_DIR}/00-priority-classes.sh" "${cluster}"
  fi
done

# --- Step 00b: Gateway API CRDs (전체 — Istio GA 대비) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [00b] Installing Gateway API CRDs on ${cluster} ---"
    run "${SCRIPTS_DIR}/00b-gateway-api.sh" "${cluster}"
  fi
done

# --- Step 01: cert-manager (mgmt only) ---
if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "mgmt" ]]; then
  log "--- [01] Installing cert-manager on mgmt ---"
  run "${SCRIPTS_DIR}/01-cert-manager.sh" mgmt
fi

# --- Step 02: External Secrets Operator (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [02] Installing External Secrets Operator on ${cluster} ---"
    run "${SCRIPTS_DIR}/02-external-secrets.sh" "${cluster}"
  fi
done

# --- Step 03: Stakater Reloader (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [03] Installing Stakater Reloader on ${cluster} ---"
    run "${SCRIPTS_DIR}/03-reloader.sh" "${cluster}"
  fi
done

# --- Step 04: Istio asm-1-28 (mgmt, app1) ---
for cluster in mgmt app1; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [04] Enabling Istio asm-1-28 on ${cluster} ---"
    run "${SCRIPTS_DIR}/04-istio.sh" "${cluster}"
  fi
done

# --- Step 05: Kyverno (app1, app2 — ADR-003/C4) ---
for cluster in app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [05] Installing Kyverno on ${cluster} ---"
    run "${SCRIPTS_DIR}/05-kyverno.sh" "${cluster}"
  fi
done

# --- Step 06: Flux v2 (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [06] Enabling Flux v2 on ${cluster} ---"
    run "${SCRIPTS_DIR}/06-flux.sh" "${cluster}"
  fi
done

# --- Step 07: Kiali v2.21 (mgmt only) ---
if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "mgmt" ]]; then
  log "--- [07] Installing Kiali on mgmt ---"
  run "${SCRIPTS_DIR}/07-kiali.sh" mgmt
fi

# --- Step 08: Karpenter NodePool CRDs (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [08] Configuring Karpenter NodePool on ${cluster} ---"
    run "${SCRIPTS_DIR}/08-karpenter-nodepool.sh" "${cluster}"
  fi
done

# --- Step 09: AKS Backup Extension (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [09] Installing AKS Backup Extension on ${cluster} ---"
    run "${SCRIPTS_DIR}/09-backup-extension.sh" "${cluster}"
  fi
done

# --- Step 10: Defender for Containers 검증 (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [10] Verifying Defender for Containers on ${cluster} ---"
    run "${SCRIPTS_DIR}/10-defender.sh" "${cluster}"
  fi
done

# --- Step 11: Budget Alert ($250/월) ---
if [[ "${CLUSTER_TARGET}" == "all" ]]; then
  log "--- [11] Setting up Budget Alert ---"
  run "${SCRIPTS_DIR}/11-budget-alert.sh"
fi

# --- Step 12: AKS Stop/Start Automation ---
if [[ "${CLUSTER_TARGET}" == "all" ]]; then
  log "--- [12] Setting up AKS Stop/Start Automation ---"
  run "${SCRIPTS_DIR}/12-aks-automation.sh"
fi

# --- Step 13: Cilium Hubble UI (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [13] Enabling Cilium Hubble on ${cluster} ---"
    run "${SCRIPTS_DIR}/13-hubble.sh" "${cluster}"
  fi
done

# --- Step 14: 최종 검증 ---
if [[ "${CLUSTER_TARGET}" == "all" ]]; then
  log "--- [14] Running cluster verification ---"
  run "${SCRIPTS_DIR}/14-verify-clusters.sh"
fi

echo ""
log "=== Phase 2 complete ==="
