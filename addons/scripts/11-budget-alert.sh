#!/usr/bin/env bash
# ============================================================
# 11-budget-alert.sh — Create Azure Budget Alert ($250/month)
#
# ADR-012 / C10: Budget Alert + AKS Stop/Start automation
# Alerts at 80% ($200) and 100% ($250) of monthly budget.
#
# Usage: ./11-budget-alert.sh
# ============================================================
set -euo pipefail

echo "[budget] Creating Azure Budget Alert ($250/month)"

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID env var}"
BUDGET_NAME="budget-k8s-demo"
ALERT_EMAIL="${BUDGET_ALERT_EMAIL:?Set BUDGET_ALERT_EMAIL env var}"
AMOUNT=250

# Create budget via Azure CLI
az consumption budget create \
  --budget-name "${BUDGET_NAME}" \
  --amount "${AMOUNT}" \
  --time-grain Monthly \
  --category Cost \
  --subscription "${SUBSCRIPTION_ID}" \
  --notifications "[
    {
      \"enabled\": true,
      \"operator\": \"GreaterThan\",
      \"threshold\": 80,
      \"contactEmails\": [\"${ALERT_EMAIL}\"],
      \"thresholdType\": \"Actual\"
    },
    {
      \"enabled\": true,
      \"operator\": \"GreaterThan\",
      \"threshold\": 100,
      \"contactEmails\": [\"${ALERT_EMAIL}\"],
      \"thresholdType\": \"Actual\"
    }
  ]"

echo "[budget] ✓ Budget '${BUDGET_NAME}' created: \$${AMOUNT}/month"
echo "[budget] Alerts at 80% (\$200) and 100% (\$250) → ${ALERT_EMAIL}"
