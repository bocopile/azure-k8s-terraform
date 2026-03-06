# ============================================================
# modules/identity/main.tf
# Managed Identities + Role Assignments per cluster
# ============================================================

# ============================================================
# Control Plane Identity (AKS cluster identity)
# ============================================================

resource "azurerm_user_assigned_identity" "control_plane" {
  for_each = var.clusters

  name                = "mi-aks-cp-${each.key}"
  location            = var.location
  resource_group_name = var.rg_common
  tags                = var.tags
}

# ============================================================
# Kubelet Identity (node pool identity)
# ============================================================

resource "azurerm_user_assigned_identity" "kubelet" {
  for_each = var.clusters

  name                = "mi-aks-kubelet-${each.key}"
  location            = var.location
  resource_group_name = var.rg_common
  tags                = var.tags
}

# ============================================================
# cert-manager Workload Identity
# (one per cluster — DNS-01 challenge + Key Vault access)
# ============================================================

resource "azurerm_user_assigned_identity" "cert_manager" {
  for_each = var.clusters

  name                = "mi-cert-manager-${each.key}"
  location            = var.location
  resource_group_name = var.rg_common
  tags                = var.tags
}

# ============================================================
# Role Assignments — Control Plane → Managed Identity Operator (Kubelet)
# AKS가 Kubelet Identity를 노드에 할당하려면 이 권한이 필요
# ============================================================

resource "azurerm_role_assignment" "cp_mi_operator_kubelet" {
  for_each = var.clusters

  principal_id         = azurerm_user_assigned_identity.control_plane[each.key].principal_id
  role_definition_name = "Managed Identity Operator"
  scope                = azurerm_user_assigned_identity.kubelet[each.key].id

  skip_service_principal_aad_check = true
}

# ============================================================
# Role Assignments — Kubelet → AcrPull
# ============================================================

resource "azurerm_role_assignment" "kubelet_acrpull" {
  for_each = var.clusters

  principal_id         = azurerm_user_assigned_identity.kubelet[each.key].principal_id
  role_definition_name = "AcrPull"
  scope                = var.acr_id

  # Avoid re-creation on service principal propagation delay
  skip_service_principal_aad_check = true
}

# ============================================================
# Role Assignments — Control Plane → Network Contributor (VNet)
# Required for AKS to manage NIC/LB in the VNet
# ============================================================

resource "azurerm_role_assignment" "cp_network_contributor" {
  for_each = var.clusters

  principal_id         = azurerm_user_assigned_identity.control_plane[each.key].principal_id
  role_definition_name = "Network Contributor"
  scope                = var.vnet_ids[each.value.vnet_key]

  skip_service_principal_aad_check = true
}

# ============================================================
# Role Assignments — Control Plane → Private DNS Zone Contributor
# AKS Private Cluster가 공유 DNS Zone에 레코드 등록 필요
# ============================================================

resource "azurerm_role_assignment" "cp_dns_contributor" {
  for_each = var.enable_dns_role_assignment ? var.clusters : {}

  principal_id         = azurerm_user_assigned_identity.control_plane[each.key].principal_id
  role_definition_name = "Private DNS Zone Contributor"
  scope                = var.aks_private_dns_zone_id

  skip_service_principal_aad_check = true
}

# ============================================================
# Role Assignments — cert-manager → DNS Zone Contributor
# (only when dns_zone_id is set)
# ============================================================

resource "azurerm_role_assignment" "cert_manager_dns" {
  for_each = var.dns_zone_id != "" ? var.clusters : {}

  principal_id         = azurerm_user_assigned_identity.cert_manager[each.key].principal_id
  role_definition_name = "DNS Zone Contributor"
  scope                = var.dns_zone_id

  skip_service_principal_aad_check = true
}

# ============================================================
# Role Assignments — cert-manager → Key Vault Secrets Officer
# ============================================================

resource "azurerm_role_assignment" "cert_manager_kv" {
  for_each = var.clusters

  principal_id         = azurerm_user_assigned_identity.cert_manager[each.key].principal_id
  role_definition_name = "Key Vault Secrets Officer"
  scope                = var.key_vault_id

  skip_service_principal_aad_check = true
}

# ============================================================
# External Secrets Operator (ESO) Workload Identity
# 클러스터당 1개 — Key Vault 시크릿 동기화 전용 (최소 권한: Secrets User)
# ============================================================

resource "azurerm_user_assigned_identity" "eso" {
  for_each = var.clusters

  name                = "mi-eso-${each.key}"
  location            = var.location
  resource_group_name = var.rg_common
  tags                = var.tags
}

# ESO MI → Key Vault Secrets User (읽기 전용 — cert-manager와 분리)
resource "azurerm_role_assignment" "eso_kv" {
  for_each = var.clusters

  principal_id         = azurerm_user_assigned_identity.eso[each.key].principal_id
  role_definition_name = "Key Vault Secrets User"
  scope                = var.key_vault_id

  skip_service_principal_aad_check = true
}
