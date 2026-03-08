# ============================================================
# addons.tf — Phase 2 Addon Installation (local-exec)
#
# tofu apply 한 번으로 인프라 + 애드온 전체 배포.
# enable_addon_install = true 설정 시 AKS 생성 후 자동으로
# addons/install.sh --cluster all을 로컬에서 실행합니다.
#
# 전제 조건 (tofu apply 실행 머신):
#   - az CLI 설치 및 az login 완료
#   - kubectl, helm, kubelogin 설치됨
#   - addon_env 에 LETSENCRYPT_EMAIL, GITOPS_REPO_URL 등 필요 값 설정
#
# 트리거: 클러스터 재생성 또는 install.sh 변경 시 재실행
# ============================================================

resource "null_resource" "addon_install" {
  count = var.enable_addon_install ? 1 : 0

  triggers = {
    # 클러스터 ID 변경(재생성) 시 재실행
    cluster_ids  = join(",", [for k, v in module.aks.cluster_ids : v])
    # install.sh 변경 시 재실행
    install_hash = filemd5("${path.module}/addons/install.sh")
    # addon_env 변경 시 재실행
    addon_env_hash = sha256(jsonencode(var.addon_env))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      echo "[addons.tf] ========================================"
      echo "[addons.tf] Phase 2 Addon 설치 시작"
      echo "[addons.tf] prefix=${local.prefix}, location=${local.location}"
      echo "[addons.tf] ========================================"

      # ── 기본 환경변수
      export PREFIX="${local.prefix}"
      export LOCATION="${local.location}"
      export AZURE_SUBSCRIPTION_ID="${var.subscription_id}"
      export AZURE_TENANT_ID="${var.tenant_id}"

      # ── addon_env 맵에서 추가 환경변수 export
      %{~ for k, v in var.addon_env}
      export ${k}="${v}"
      %{~ endfor}

      # ── kubeconfig 설정 (3개 클러스터)
      echo "[addons.tf] kubeconfig 설정 중..."
      for cluster in mgmt app1 app2; do
        az aks get-credentials \
          --resource-group "rg-${local.prefix}-$${cluster}" \
          --name "aks-$${cluster}" \
          --overwrite-existing \
          --only-show-errors
      done

      # ── 전체 애드온 설치
      echo "[addons.tf] install.sh 실행 중..."
      bash "${path.module}/addons/install.sh" \
        --cluster all \
        --prefix "${local.prefix}" \
        --location "${local.location}"

      echo "[addons.tf] ✓ 전체 애드온 설치 완료"
    EOT
  }

  depends_on = [
    module.aks,
    module.backup,
    module.keyvault,
    azurerm_key_vault_secret.flux_ssh_key,
  ]
}
