# ============================================================
# backend.tf — Terraform State Backend Configuration
#
# 현재: Local backend (개발/PoC 단계)
# 전환: Azure Blob Storage backend (팀 협업 / 프로덕션)
#
# 전환 절차:
#   1. tfstate용 Storage Account 생성 (IaC 외부 — 부트스트랩)
#      az group create --name rg-tfstate --location koreacentral
#      az storage account create \
#        --name <globally-unique-name> \
#        --resource-group rg-tfstate \
#        --sku Standard_LRS \
#        --allow-blob-public-access false \
#        --min-tls-version TLS1_2
#      az storage container create \
#        --name tfstate \
#        --account-name <globally-unique-name>
#
#   2. 아래 backend "local" {} 블록을 삭제하고
#      backend "azurerm" {} 블록의 주석을 해제한 뒤 값 수정
#
#   3. State 마이그레이션 실행
#      tofu init -migrate-state
#      # → "Do you want to copy existing state to the new backend?" 에 yes
#
#   4. 로컬 state 파일 정리 (선택)
#      rm terraform.tfstate terraform.tfstate.backup
#
# 참고:
#   - State Locking: Blob Lease 기반 자동 잠금 (동시 apply 방지)
#   - 암호화: Azure Storage 기본 AES-256 + 선택적 CMK
#   - 접근 제어: Storage Blob Data Contributor RBAC 권장
#   - 버전 관리: Storage Account Versioning 활성화로 state 이력 보존
# ============================================================

terraform {
  # ── Active: Local backend (dev/PoC) ──
  backend "local" {}

  # ── 전환 대상: Azure Blob Storage backend ──
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "<globally-unique-name>"  # 실제 Storage Account 이름으로 변경
  #   container_name       = "tfstate"
  #   key                  = "azure-k8s/main.tfstate"
  #   use_azuread_auth     = true  # MSI/OIDC 인증 — Access Key 불필요
  # }
}
