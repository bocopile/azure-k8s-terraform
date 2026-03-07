#!/usr/bin/env bash
# ============================================================
# scripts/init-backend.sh — Remote Backend 초기화 스크립트
#
# 방법 A (Azure AD RBAC) + 방법 B (스토리지 키 fallback) 자동 처리
#
# 동작 순서:
#   1. backend.tf에서 storage_account_name 자동 파싱
#   2. Azure AD 인증으로 RBAC 전파 확인 (방법 B)
#   3. RBAC 미전파 시 스토리지 키 자동 주입 (방법 A fallback)
#   4. tofu init 실행
#   5. 이후 tofu validate / plan으로 이어가기
#
# Usage: ./scripts/init-backend.sh [--migrate-state]
#   --migrate-state: 로컬 state를 remote backend로 마이그레이션 시
# ============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${0}")/.." && pwd)"
cd "${REPO_ROOT}"

MIGRATE="${1:-}"

# ---- backend.tf에서 설정 파싱 ----
BACKEND_FILE="backend.tf"
SA_NAME=$(grep 'storage_account_name' "${BACKEND_FILE}" | sed 's/.*= *"\(.*\)".*/\1/')
RG_NAME=$(grep 'resource_group_name' "${BACKEND_FILE}" | sed 's/.*= *"\(.*\)".*/\1/')
CONTAINER=$(grep 'container_name' "${BACKEND_FILE}" | sed 's/.*= *"\(.*\)".*/\1/')
# backend.tf에서 location 파싱 (주석 제외), 없으면 환경변수 또는 기본값 사용
BACKEND_LOCATION=$(grep -v '^[[:space:]]*#' "${BACKEND_FILE}" | grep 'location' | sed 's/.*= *"\(.*\)".*/\1/' | head -1 || true)
LOCATION="${BACKEND_LOCATION:-koreacentral}"

echo "============================================================"
echo "  Backend 설정"
echo "  Storage Account : ${SA_NAME}"
echo "  Resource Group  : ${RG_NAME}"
echo "  Container       : ${CONTAINER}"
echo "============================================================"

# ---- Azure 로그인 확인 ----
if ! az account show &>/dev/null; then
  echo "[ERROR] az login이 필요합니다."
  echo "  az login"
  echo "  az account set --subscription <SUBSCRIPTION_ID>"
  exit 1
fi

SUB_ID=$(az account show --query id -o tsv)
echo "[info] 구독: ${SUB_ID}"

# ---- Storage Account 존재 여부 확인 ----
if ! az storage account show --name "${SA_NAME}" --resource-group "${RG_NAME}" &>/dev/null; then
  echo "[info] Storage Account '${SA_NAME}'이 없습니다. 생성 중..."

  az group create --name "${RG_NAME}" --location "${LOCATION}" -o none
  az storage account create \
    --name "${SA_NAME}" \
    --resource-group "${RG_NAME}" \
    --location "${LOCATION}" \
    --sku Standard_LRS \
    --allow-blob-public-access false \
    -o none
  az storage container create \
    --name "${CONTAINER}" \
    --account-name "${SA_NAME}" \
    --auth-mode login \
    -o none

  echo "[info] Storage Account + Container 생성 완료"

  # RBAC: 현재 사용자에게 Storage Blob Data Contributor 부여
  CURRENT_USER=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
  if [[ -n "${CURRENT_USER}" ]]; then
    STORAGE_ID=$(az storage account show --name "${SA_NAME}" --resource-group "${RG_NAME}" --query id -o tsv)
    az role assignment create \
      --assignee "${CURRENT_USER}" \
      --role "Storage Blob Data Contributor" \
      --scope "${STORAGE_ID}" \
      -o none 2>/dev/null || echo "[warn] 역할 부여 실패 (이미 존재하거나 권한 부족)"
    echo "[info] Storage Blob Data Contributor 역할 부여 완료 (전파에 1~5분 소요)"
  fi
fi

# ---- 방법 B: Azure AD RBAC 전파 확인 ----
echo ""
echo "[B] Azure AD 인증으로 RBAC 전파 확인 중..."

RBAC_OK=false
MAX_WAIT=300   # 최대 5분 대기
ELAPSED=0
INTERVAL=15

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
  if az storage blob list \
      --container-name "${CONTAINER}" \
      --account-name "${SA_NAME}" \
      --auth-mode login \
      --query "length(@)" -o tsv &>/dev/null; then
    RBAC_OK=true
    echo "[B] RBAC 전파 완료 — Azure AD 인증 사용"
    break
  fi

  echo "[B] RBAC 전파 대기 중... (${ELAPSED}s / ${MAX_WAIT}s)"
  sleep ${INTERVAL}
  ELAPSED=$(( ELAPSED + INTERVAL ))
done

# ---- 방법 A: RBAC 미전파 시 스토리지 키 fallback ----
if [[ "${RBAC_OK}" == "false" ]]; then
  echo ""
  echo "[A] RBAC 미전파 — 스토리지 키 fallback 적용"
  STORAGE_KEY=$(az storage account keys list \
    --account-name "${SA_NAME}" \
    --resource-group "${RG_NAME}" \
    --query "[0].value" -o tsv)
  export ARM_ACCESS_KEY="${STORAGE_KEY}"
  echo "[A] ARM_ACCESS_KEY 환경변수 설정 완료 (현재 세션 한정)"
  echo "[A] 참고: RBAC 전파 완료 후에는 ARM_ACCESS_KEY 없이 tofu 명령 사용 가능"
fi

# ---- tofu init ----
echo ""
echo "[info] tofu init 실행 중..."
if [[ "${MIGRATE}" == "--migrate-state" ]]; then
  tofu init -migrate-state
else
  tofu init
fi

echo ""
echo "============================================================"
echo "  초기화 완료"
echo ""
echo "  다음 단계:"
echo "  tofu validate"
echo "  tofu plan -out=tfplan"
echo "  tofu apply tfplan"
echo ""
if [[ "${RBAC_OK}" == "false" ]]; then
  echo "  [주의] ARM_ACCESS_KEY는 현재 터미널 세션에만 유효합니다."
  echo "  새 터미널에서 tofu 명령 실행 시 아래를 먼저 실행하세요:"
  echo "    export ARM_ACCESS_KEY=\$(az storage account keys list \\"
  echo "      --account-name ${SA_NAME} --resource-group ${RG_NAME} \\"
  echo "      --query '[0].value' -o tsv)"
fi
echo "============================================================"
