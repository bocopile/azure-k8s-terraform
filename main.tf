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

  # Backend: Local (dev phase)
  # ──────────────────────────────────────────────────────────
  # Blob Storage 전환 절차:
  #   1. az storage account create --name <unique> --resource-group rg-tfstate --sku Standard_LRS
  #   2. az storage container create --name tfstate --account-name <unique>
  #   3. 아래 backend "azurerm" 블록 주석 해제 후 backend "local" {} 제거
  #   4. tofu init -migrate-state   ← 로컬 state 자동 이전
  #   5. rm terraform.tfstate terraform.tfstate.backup
  # ──────────────────────────────────────────────────────────
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "<globally-unique-name>"
  #   container_name       = "tfstate"
  #   key                  = "azure-k8s-demo/main.tfstate"
  #   use_azuread_auth     = true   # MSI/OIDC — credentials 불필요
  # }
  backend "local" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}

# ============================================================
# Module calls
# Dependency graph (단방향):
#   network → keyvault → identity → aks
#              acr    ↗
#           monitoring ↗
#           backup ↗
#   federation.tf (root): identity + aks outputs 참조 (별도 파일)
# ============================================================

module "network" {
  source = "./modules/network"

  location            = local.location
  prefix              = local.prefix
  rg_common           = local.rg_common
  vnets               = local.vnets
  aks_subnets         = local.aks_subnets
  bastion_subnet_cidr = local.bastion_subnet_cidr
  jumpbox_subnet_cidr = local.jumpbox_subnet_cidr
  pe_subnet_cidr      = local.pe_subnet_cidr
  tags                = var.tags
}

module "keyvault" {
  source = "./modules/keyvault"

  location      = local.location
  rg_common     = local.rg_common
  name          = local.names.key_vault
  tenant_id     = var.tenant_id
  pe_subnet_id  = module.network.pe_subnet_id
  vnet_ids      = module.network.vnet_ids
  tags          = var.tags

  depends_on = [module.network]
}

module "acr" {
  source = "./modules/acr"

  location  = local.location
  rg_common = local.rg_common
  name      = local.names.acr
  tags      = var.tags

  # 의존성 없음 — AcrPull role assignment는 identity 모듈에서 처리
  depends_on = [module.network]
}

# identity는 acr + keyvault 이후 생성 (단방향)
module "identity" {
  source = "./modules/identity"

  location     = local.location
  rg_common    = local.rg_common
  clusters     = local.clusters
  acr_id       = module.acr.acr_id
  vnet_ids     = module.network.vnet_ids
  key_vault_id = module.keyvault.key_vault_id
  dns_zone_id  = "" # Azure DNS Zone ID (cert-manager DNS-01 챌린지용, 설정 시 입력)
  tags         = var.tags

  depends_on = [module.network, module.acr, module.keyvault]
}

module "monitoring" {
  source = "./modules/monitoring"

  location               = local.location
  rg_common              = local.rg_common
  log_analytics_name     = local.names.log_analytics
  monitor_workspace_name = local.names.monitor_workspace
  app_insights_name      = local.names.app_insights
  tags                   = var.tags

  depends_on = [module.network]
}

module "backup" {
  source = "./modules/backup"

  location           = local.location
  rg_common          = local.rg_common
  vault_name         = local.names.backup_vault
  policy_name        = local.names.backup_policy
  enable_soft_delete = false # Demo: 즉시 삭제 허용 (prod 전환 시 true)
  tags               = var.tags

  depends_on = [module.network]
}

module "aks" {
  source = "./modules/aks"

  location              = local.location
  zones                 = local.zones
  prefix                = local.prefix
  kubernetes_version    = local.kubernetes_version
  vm_sizes              = local.vm_sizes
  clusters              = local.clusters
  clusters_with_ingress = local.clusters_with_ingress
  rg_cluster            = local.rg_cluster
  rg_common             = local.rg_common

  subnet_ids        = module.network.aks_subnet_ids
  bastion_subnet_id = module.network.bastion_subnet_id
  jumpbox_subnet_id = module.network.jumpbox_subnet_id

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

  tags = var.tags

  depends_on = [module.network, module.identity, module.monitoring]
}
