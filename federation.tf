# ============================================================
# federation.tf — Workload Identity Federated Credentials
#
# AKS 클러스터가 생성된 후 OIDC Issuer URL이 확정되므로
# 루트 레벨에서 identity + aks 모듈 output을 참조하여 구성.
#
# 대상: cert-manager (DNS-01 챌린지 + Key Vault Secrets Officer)
# 참고: ARCHITECTURE.md §7.3, ADR-017
# ============================================================

# cert-manager Federated Credential — 클러스터당 1개
resource "azurerm_federated_identity_credential" "cert_manager" {
  for_each = local.clusters

  name                = "fedcred-cert-manager-${each.key}"
  resource_group_name = local.rg_common
  parent_id           = module.identity.cert_manager_identity_ids[each.key]

  # OIDC Issuer URL은 AKS 생성 후 확정
  issuer = module.aks.oidc_issuer_urls[each.key]

  # cert-manager가 사용하는 K8s ServiceAccount
  # Namespace: cert-manager, SA name: cert-manager
  subject = "system:serviceaccount:cert-manager:cert-manager"

  audience = ["api://AzureADTokenExchange"]

  depends_on = [module.identity, module.aks]
}
