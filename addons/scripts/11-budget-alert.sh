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

echo "[budget] Creating Azure Budget Alert (\$250/month)"

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID env var}"
BUDGET_NAME="budget-${PREFIX:-k8s}"

if [[ -z "${BUDGET_ALERT_EMAIL:-}" ]]; then
  echo "[budget] BUDGET_ALERT_EMAIL 미설정 — Budget Alert 건너뜀"
  echo "[budget] 설정 방법: export BUDGET_ALERT_EMAIL=admin@example.com"
  exit 0
fi
ALERT_EMAIL="${BUDGET_ALERT_EMAIL}"
AMOUNT=250

# 예산 기간: 이번 달 1일 ~ 5년 후
START_DATE="$(date +%Y-%m)-01"
END_DATE="$(date -v+5y +%Y-%m)-01"

# ARM REST API로 알림 포함 예산 생성 (az consumption budget create는 알림 미지원)
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Consumption/budgets/${BUDGET_NAME}?api-version=2023-11-01" \
  --body "{
    \"properties\": {
      \"category\": \"Cost\",
      \"amount\": ${AMOUNT},
      \"timeGrain\": \"Monthly\",
      \"timePeriod\": {
        \"startDate\": \"${START_DATE}\",
        \"endDate\": \"${END_DATE}\"
      },
      \"notifications\": {
        \"alert80\": {
          \"enabled\": true,
          \"operator\": \"GreaterThan\",
          \"threshold\": 80,
          \"contactEmails\": [\"${ALERT_EMAIL}\"],
          \"thresholdType\": \"Actual\"
        },
        \"alert100\": {
          \"enabled\": true,
          \"operator\": \"GreaterThan\",
          \"threshold\": 100,
          \"contactEmails\": [\"${ALERT_EMAIL}\"],
          \"thresholdType\": \"Actual\"
        }
      }
    }
  }" 2>&1

echo "[budget] ✓ Budget '${BUDGET_NAME}' created: \$${AMOUNT}/month"
echo "[budget] Alerts at 80% (\$200) and 100% (\$250) → ${ALERT_EMAIL}"

