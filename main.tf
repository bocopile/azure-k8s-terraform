# ============================================================
# main.tf — Provider configuration + module orchestration
# ============================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Backend 설정은 backend.tf에서 관리
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  features {
    key_vault {
      # false: destroy 후 soft-deleted 상태 유지 (안전, 수동 purge 필요)
      # true:  destroy 시 즉시 purge (편의성↑, 데이터 손실 위험↑)
      # 상세 절차: DESTROY.md §4 참조
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# azuread provider — Sentinel Data Connector + 향후 Entra ID 연동 대비
provider "azuread" {
  tenant_id = var.tenant_id
}

# ============================================================
# Module calls
# Dependency graph (단방향):
#   resource_group → network → monitoring → keyvault → identity → aks
#                    acr       ↗
#                    backup    (independent)
#   flow-logs.tf (root): network + monitoring outputs 참조
#   federation.tf (root): identity + aks outputs 참조 (별도 파일)
# ============================================================

module "resource_group" {
  source = "./modules/resource-group"

  location   = local.location
  rg_common  = local.rg_common
  rg_cluster = local.rg_cluster
  tags       = var.tags
}

module "network" {
  source = "./modules/network"

  location  = local.location
  rg_common = local.rg_common
  vnets               = local.vnets
  aks_subnets         = local.aks_subnets
  bastion_subnet_cidr = local.bastion_subnet_cidr
  jumpbox_subnet_cidr = local.jumpbox_subnet_cidr
  pe_subnet_cidr      = local.pe_subnet_cidr
  tags                = var.tags

  depends_on = [module.resource_group]
}

module "keyvault" {
  source = "./modules/keyvault"

  location                   = local.location
  rg_common                  = local.rg_common
  name                       = local.names.key_vault
  tenant_id                  = var.tenant_id
  sku_name                   = var.keyvault_sku
  purge_protection           = var.keyvault_purge_protection
  pe_subnet_id               = module.network.pe_subnet_id
  vnet_ids                   = module.network.vnet_ids
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  enable_diagnostics         = true
  tags                       = var.tags

  depends_on = [module.resource_group, module.network, module.monitoring]
}

module "acr" {
  source = "./modules/acr"

  location  = local.location
  rg_common = local.rg_common
  name      = local.names.acr
  sku       = var.acr_sku
  tags      = var.tags

  # 의존성: resource_group만 필요 (ACR은 network와 독립)
  depends_on = [module.resource_group]
}

# identity는 acr + keyvault 이후 생성 (단방향)
module "identity" {
  source = "./modules/identity"

  location                = local.location
  rg_common               = local.rg_common
  clusters                = local.clusters
  acr_id                  = module.acr.acr_id
  vnet_ids                = module.network.vnet_ids
  key_vault_id            = module.keyvault.key_vault_id
  aks_private_dns_zone_id   = module.network.aks_private_dns_zone_id
  enable_dns_role_assignment = true
  dns_zone_id               = var.dns_zone_id
  tags                    = var.tags

  depends_on = [module.resource_group, module.network, module.acr, module.keyvault]
}

module "monitoring" {
  source = "./modules/monitoring"

  location               = local.location
  rg_common              = local.rg_common
  log_analytics_name     = local.names.log_analytics
  monitor_workspace_name = local.names.monitor_workspace
  app_insights_name      = local.names.app_insights
  grafana_name           = local.names.grafana
  enable_grafana         = var.enable_grafana
  enable_sentinel        = var.enable_sentinel
  log_retention_days     = var.log_retention_days
  grafana_public_access  = var.grafana_public_access
  grafana_sku            = var.grafana_sku
  tags                   = var.tags

  depends_on = [module.resource_group]
}

module "backup" {
  source = "./modules/backup"

  location                  = local.location
  rg_common                 = local.rg_common
  vault_name                = local.names.backup_vault
  policy_name               = local.names.backup_policy
  enable_soft_delete        = var.backup_soft_delete
  backup_retention_duration = var.backup_retention_duration
  tags                      = var.tags

  depends_on = [module.resource_group]
}

module "aks" {
  source = "./modules/aks"

  location              = local.location
  zones                 = local.zones
  prefix                = local.prefix
  tenant_id             = var.tenant_id
  kubernetes_version    = local.kubernetes_version
  vm_sizes              = local.vm_sizes
  clusters              = local.clusters
  clusters_with_ingress = local.clusters_with_ingress
  rg_cluster            = local.rg_cluster
  rg_common             = local.rg_common

  subnet_ids              = module.network.aks_subnet_ids
  bastion_subnet_id       = module.network.bastion_subnet_id
  jumpbox_subnet_id       = module.network.jumpbox_subnet_id
  aks_private_dns_zone_id = module.network.aks_private_dns_zone_id

  control_plane_identity_ids = module.identity.control_plane_identity_ids
  kubelet_identity_ids       = module.identity.kubelet_identity_ids
  kubelet_client_ids         = module.identity.kubelet_client_ids
  kubelet_object_ids         = module.identity.kubelet_object_ids

  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  monitor_workspace_id       = module.monitoring.monitor_workspace_id

  jumpbox_admin_username = var.jumpbox_admin_username
  jumpbox_ssh_public_key = var.jumpbox_ssh_public_key
  jumpbox_vm_name        = local.names.jumpbox_vm
  jumpbox_nic_name       = local.names.jumpbox_nic
  jumpbox_private_ip     = local.jumpbox_private_ip
  bastion_name           = local.names.bastion
  bastion_pip_name       = local.names.bastion_pip
  aks_sku_tier           = var.aks_sku_tier
  bastion_sku            = var.bastion_sku

  tags = var.tags

  depends_on = [module.resource_group, module.network, module.identity, module.monitoring]
}
