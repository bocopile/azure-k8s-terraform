#!/usr/bin/env bash
# ============================================================
# 12-aks-automation.sh — AKS Stop/Start Automation (야간 절약)
#
# ADR-012 / C10: AKS clusters stopped at 22:00 KST, started at 09:00 KST
# Implemented via Azure Automation Account Runbooks (or Event Grid / Logic App)
#
# This script is a STUB — implement via Azure Automation or GitHub Actions:
#   Option A: Azure Automation Runbook (PowerShell/Python)
#   Option B: GitHub Actions scheduled workflow
#   Option C: Azure Logic App with recurrence trigger
#
# Usage: ./12-aks-automation.sh
# ============================================================
set -euo pipefail

echo "[aks-automation] Setting up AKS Stop/Start schedule"

CLUSTERS=("aks-mgmt" "aks-app1" "aks-app2")
RGS=("rg-k8s-demo-mgmt" "rg-k8s-demo-app1" "rg-k8s-demo-app2")

echo "[aks-automation] Clusters to manage:"
for i in "${!CLUSTERS[@]}"; do
  echo "  - ${CLUSTERS[$i]} in ${RGS[$i]}"
done

echo ""
echo "[aks-automation] TODO: Choose one automation method:"
echo ""
echo "  [Option A] Azure CLI manual stop/start:"
echo "    # Stop (save costs at night)"
for i in "${!CLUSTERS[@]}"; do
  echo "    az aks stop --name ${CLUSTERS[$i]} --resource-group ${RGS[$i]}"
done
echo "    # Start"
for i in "${!CLUSTERS[@]}"; do
  echo "    az aks start --name ${CLUSTERS[$i]} --resource-group ${RGS[$i]}"
done
echo ""
echo "  [Option B] GitHub Actions: Create .github/workflows/aks-schedule.yml"
echo "    - cron: '0 13 * * *'  # 22:00 KST = 13:00 UTC → STOP"
echo "    - cron: '0 0 * * *'   # 09:00 KST = 00:00 UTC → START"

echo ""
echo "[aks-automation] ⚠ Automation not yet configured. Implement Option A or B."
