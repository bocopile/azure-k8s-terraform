#!/usr/bin/env bash
# ============================================================
# 12-aks-automation.sh — AKS Stop/Start Automation (야간 절약)
#
# ADR-012 / C10: AKS clusters stopped at 22:00 KST, started at 09:00 KST
# GitHub Actions 스케줄 워크플로우로 구현됨:
#   .github/workflows/aks-schedule.yml
#
# 수동 실행이 필요한 경우 아래 명령 사용
# Usage: ./12-aks-automation.sh [stop|start]
# ============================================================
set -euo pipefail

ACTION="${1:-}"
PREFIX="${PREFIX:-k8s}"

CLUSTERS=("mgmt" "app1" "app2")

if [[ -z "${ACTION}" ]]; then
  echo "[aks-automation] GitHub Actions 워크플로우: .github/workflows/aks-schedule.yml"
  echo "[aks-automation] 스케줄: 22:00 KST STOP / 09:00 KST START (평일)"
  echo ""
  echo "[aks-automation] 수동 실행: ./12-aks-automation.sh stop|start"
  exit 0
fi

if [[ "${ACTION}" != "stop" && "${ACTION}" != "start" ]]; then
  echo "ERROR: action must be 'stop' or 'start'" >&2
  exit 1
fi

echo "[aks-automation] ${ACTION} — 클러스터 전체"

for cluster in "${CLUSTERS[@]}"; do
  RG="rg-${PREFIX}-${cluster}"
  NAME="aks-${cluster}"
  echo "[aks-automation] az aks ${ACTION} --name ${NAME} --resource-group ${RG}"
  az aks "${ACTION}" --name "${NAME}" --resource-group "${RG}" --no-wait
done

echo "[aks-automation] 완료 (--no-wait). 상태 확인:"
for cluster in "${CLUSTERS[@]}"; do
  echo "  az aks show -g rg-${PREFIX}-${cluster} -n aks-${cluster} --query powerState.code -o tsv"
done
