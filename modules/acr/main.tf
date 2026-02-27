# ============================================================
# modules/acr/main.tf
# Azure Container Registry — Basic SKU
# AcrPull role is assigned in modules/identity/ (kubelet identity)
# ============================================================

resource "azurerm_container_registry" "acr" {
  name                = var.name
  location            = var.location
  resource_group_name = var.rg_common
  sku                 = "Basic"

  # Admin credentials disabled — use Workload Identity / Kubelet Identity
  admin_enabled = false

  tags = var.tags
}
