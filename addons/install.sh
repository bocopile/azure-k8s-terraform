#!/usr/bin/env bash
# ============================================================
# addons/install.sh — Phase 2: Addon Installation Entry Point
# Run AFTER `tofu apply` completes successfully.
#
# 실행 순서 (ARCHITECTURE.md §12 설치 워크플로우):
#   13  hubble            — Cilium ACNS/Hubble (전체) ★ 반드시 먼저: ACNS가 Cilium 재시작 유발
#   00  priority-classes  — 스케줄링 우선순위 사전 정의
#   00b gateway-api       — Gateway API CRD (Istio GA 대비)
#   01  cert-manager      — TLS 인증서 관리 (mgmt only)
#   02  external-secrets  — ESO PushSecret (전체)
#   03  reloader          — Key Vault Auto-rotation 연동 (전체)
#   04  istio             — AKS Istio asm-1-28 (mgmt, app1)
#   04b istio-mtls        — PeerAuthentication STRICT + DestinationRule (mgmt, app1)
#   05  kyverno           — 정책 엔진 (app1, app2 only)
#   06  flux              — GitOps Flux v2 (전체)
#   07  kiali             — 서비스 메시 관찰성 (mgmt only)
#   08  karpenter-nodepool— Karpenter NodePool CRD (전체)
#   09  (skip)            — AKS Backup Extension은 Terraform(tofu apply)에서 관리
#   10  defender          — Defender for Containers 검증 (전체)
#   11  budget-alert      — $250/월 예산 알림
#   12  aks-automation    — AKS Stop/Start 자동화
#   15  tetragon          — Cilium Tetragon 런타임 보안 (전체)
#   16  otel-collector    — OpenTelemetry Collector (전체)
#   17  grafana-dashboards— Azure Managed Grafana 대시보드 프로비저닝
#   19  vpa               — Vertical Pod Autoscaler (전체)
#   14  verify-clusters   — 최종 검증 (항상 마지막)
#
# Usage:
#   chmod +x addons/install.sh
#   ./addons/install.sh [--cluster mgmt|app1|app2|all] [--prefix k8s] [--location koreacentral] [--dry-run]
#
# Prerequisites (Jump VM 또는 VPN 접속 환경):
#   - kubectl, helm, az, kubelogin 설치됨
#   - az login 완료
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# --- Prerequisite check ---
for cmd in kubectl helm az kubelogin; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed. Install it before running this script." >&2
    exit 1
  fi
done

# --- Parse arguments ---
CLUSTER_TARGET="all"
DRY_RUN=false
export PREFIX="${PREFIX:-k8s}"
export LOCATION="${LOCATION:-koreacentral}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --cluster requires a value (mgmt|app1|app2|all)" >&2
        exit 1
      fi
      CLUSTER_TARGET="$2"
      shift 2
      ;;
    --prefix)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --prefix requires a value (e.g. k8s)" >&2
        exit 1
      fi
      export PREFIX="$2"
      shift 2
      ;;
    --location)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --location requires a value (e.g. koreacentral)" >&2
        exit 1
      fi
      export LOCATION="$2"
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

# --cluster 값 검증
valid_targets="all mgmt app1 app2"
if [[ ! " ${valid_targets} " =~ " ${CLUSTER_TARGET} " ]]; then
  echo "ERROR: Invalid --cluster value '${CLUSTER_TARGET}'. Must be one of: ${valid_targets}" >&2
  exit 1
fi

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
log "Prefix: ${PREFIX}"
log "Location: ${LOCATION}"
log "Dry run: ${DRY_RUN}"
echo ""

# --- Step 13: Cilium Hubble / ACNS (전체 — 반드시 가장 먼저) ---
# ⚠️  ACNS(az aks update --enable-acns)는 Cilium agent를 재시작시킵니다.
#     이 단계를 모든 addon 설치 전에 완료해야 이후 Pod들이 CNI 오류 없이 IP를 받을 수 있습니다.
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [13] Enabling Cilium Hubble (ACNS) on ${cluster} — must run first ---"
    run "${SCRIPTS_DIR}/13-hubble.sh" "${cluster}"
  fi
done

# --- Step 00: PriorityClass (전체) ---
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

# --- Step 04b: Istio mTLS STRICT (mgmt, app1 — 04-istio.sh 이후 실행) ---
for cluster in mgmt app1; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [04b] Configuring Istio mTLS STRICT on ${cluster} ---"
    run "${SCRIPTS_DIR}/04b-istio-mtls.sh" "${cluster}"
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

# --- Step 07: Kiali (mgmt only) ---
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

# --- Step 09: AKS Backup Extension ---
# Terraform에서 azurerm_kubernetes_cluster_extension으로 관리됨 (tofu apply 시 자동 설치)
# 별도 스크립트 불필요 — 09-backup-extension.sh 삭제됨

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
# GitHub Actions 워크플로우로 구현됨: .github/workflows/aks-schedule.yml
# install.sh 단계에서는 워크플로우 존재 여부만 안내
if [[ "${CLUSTER_TARGET}" == "all" ]]; then
  log "--- [12] AKS Stop/Start Automation: .github/workflows/aks-schedule.yml 참조 ---"
fi

# Step 13: 상단으로 이동됨 (ACNS/Cilium 안정화 필수)

# --- Step 15: Cilium Tetragon 런타임 보안 (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [15] Installing Cilium Tetragon on ${cluster} ---"
    run "${SCRIPTS_DIR}/15-tetragon.sh" "${cluster}"
  fi
done

# --- Step 16: OpenTelemetry Collector (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [16] Installing OTel Collector on ${cluster} ---"
    run "${SCRIPTS_DIR}/16-otel-collector.sh" "${cluster}"
  fi
done

# --- Step 17: Grafana Dashboards (한 번만 실행) ---
if [[ "${CLUSTER_TARGET}" == "all" ]]; then
  log "--- [17] Provisioning Grafana Dashboards ---"
  run "${SCRIPTS_DIR}/17-grafana-dashboards.sh"
fi

# --- Step 19: Vertical Pod Autoscaler (전체) ---
for cluster in mgmt app1 app2; do
  if [[ "${CLUSTER_TARGET}" == "all" || "${CLUSTER_TARGET}" == "${cluster}" ]]; then
    log "--- [19] Installing VPA on ${cluster} ---"
    run "${SCRIPTS_DIR}/19-vpa.sh" "${cluster}"
  fi
done

# --- Step 14: 최종 검증 (항상 마지막) ---
if [[ "${CLUSTER_TARGET}" == "all" ]]; then
  log "--- [14] Running cluster verification ---"
  run "${SCRIPTS_DIR}/14-verify-clusters.sh"
fi

echo ""
log "=== Phase 2 complete ==="
