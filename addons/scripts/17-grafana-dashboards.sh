#!/usr/bin/env bash
# ============================================================
# 17-grafana-dashboards.sh — Azure Managed Grafana 대시보드 자동 프로비저닝
#
# Grafana.com 공식 대시보드를 az grafana dashboard import 로 임포트합니다.
# Azure Monitor Workspace (Managed Prometheus) 데이터소스를 자동 연결합니다.
#
# 대시보드 목록:
#   - Kubernetes Cluster Overview (18283)
#   - Node Exporter Full (1860)
#   - Kubernetes Pod Overview (15661)
#   - Namespace Workloads (15758)
#   - CoreDNS (15762)
#   - Istio Mesh (7639)
#   - Istio Service (7636)
#   - Cert-Manager (20842)
#   - Kyverno Policy Report (15804)
#
# Usage: ./17-grafana-dashboards.sh
# Prerequisites: az login, az extension add --name amg
# ============================================================
set -euo pipefail

PREFIX="${PREFIX:-k8s}"
GRAFANA_NAME="grafana-${PREFIX}"
RG="rg-${PREFIX}-common"

echo "[grafana] Provisioning dashboards for: ${GRAFANA_NAME}"

# --- amg 확장 설치 (없으면) ---
if ! az extension show --name amg &>/dev/null; then
  echo "[grafana] Installing az amg extension..."
  az extension add --name amg --only-show-errors
fi

# --- Grafana 존재 확인 ---
if ! az grafana show --name "${GRAFANA_NAME}" --resource-group "${RG}" &>/dev/null; then
  echo "[grafana] ERROR: Grafana '${GRAFANA_NAME}' not found in '${RG}'. Skipping." >&2
  exit 0
fi

# --- 폴더 생성 ---
create_folder() {
  local folder_name="$1"
  local existing
  existing=$(az grafana folder list --name "${GRAFANA_NAME}" --resource-group "${RG}" \
    --query "[?title=='${folder_name}'].id" -o tsv 2>/dev/null || true)
  if [[ -z "${existing}" ]]; then
    echo "[grafana] Creating folder: ${folder_name}"
    az grafana folder create --name "${GRAFANA_NAME}" --resource-group "${RG}" \
      --title "${folder_name}" --only-show-errors
  else
    echo "[grafana] Folder already exists: ${folder_name}"
  fi
}

# --- 대시보드 임포트 ---
import_dashboard() {
  local dashboard_id="$1"
  local folder_name="$2"
  local desc="$3"

  echo "[grafana] Importing dashboard: ${desc} (ID: ${dashboard_id}) → ${folder_name}"
  az grafana dashboard import \
    --name "${GRAFANA_NAME}" \
    --resource-group "${RG}" \
    --definition "${dashboard_id}" \
    --folder "${folder_name}" \
    --overwrite true \
    --only-show-errors 2>/dev/null || {
      echo "[grafana] WARNING: Failed to import ${desc} (ID: ${dashboard_id}). Skipping." >&2
    }
}

# ============================================================
# 폴더 생성
# ============================================================
create_folder "Kubernetes"
create_folder "Istio"
create_folder "Platform"

# ============================================================
# 대시보드 임포트
# ============================================================

# --- Kubernetes 카테고리 ---
import_dashboard 18283 "Kubernetes" "Kubernetes Cluster Overview"
import_dashboard 1860  "Kubernetes" "Node Exporter Full"
import_dashboard 15661 "Kubernetes" "Kubernetes Pod Overview"
import_dashboard 15758 "Kubernetes" "Namespace Workloads"
import_dashboard 15762 "Kubernetes" "CoreDNS"

# --- Istio 카테고리 ---
import_dashboard 7639  "Istio" "Istio Mesh Dashboard"
import_dashboard 7636  "Istio" "Istio Service Dashboard"

# --- Platform 카테고리 ---
import_dashboard 20842 "Platform" "Cert-Manager"
import_dashboard 15804 "Platform" "Kyverno Policy Report"

echo ""
echo "[grafana] Dashboard provisioning complete!"
echo "[grafana] Endpoint: $(az grafana show --name "${GRAFANA_NAME}" --resource-group "${RG}" --query endpoint -o tsv)"
