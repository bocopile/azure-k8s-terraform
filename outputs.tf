# ============================================================
# outputs.tf — Root-level outputs
# ============================================================

output "common_resource_group_name" {
  description = "Resource group name for shared resources (ACR, Key Vault, Monitoring, Backup)"
  value       = module.network.common_resource_group_name
}

output "cluster_resource_group_names" {
  description = "Resource group names per AKS cluster"
  value       = module.aks.resource_group_names
}

output "aks_cluster_ids" {
  description = "AKS cluster resource IDs"
  value       = module.aks.cluster_ids
}

output "aks_cluster_names" {
  description = "AKS cluster names"
  value       = module.aks.cluster_names
}

output "acr_login_server" {
  description = "Azure Container Registry login server URL"
  value       = module.acr.login_server
}

output "key_vault_uri" {
  description = "Azure Key Vault URI"
  value       = module.keyvault.vault_uri
}

output "log_analytics_workspace_id" {
  description = "Log Analytics Workspace resource ID"
  value       = module.monitoring.log_analytics_workspace_id
}

output "kubeconfig_commands" {
  description = "Commands to retrieve kubeconfig for each cluster"
  value = {
    for k, v in local.clusters :
    k => "az aks get-credentials --resource-group ${local.rg_cluster[k]} --name aks-${k} --file ~/.kube/config-${k}"
  }
}

output "jumpbox_private_ip" {
  description = "Jump VM private IP address (accessible via Azure Bastion)"
  value       = module.aks.jumpbox_private_ip
}

output "oidc_issuer_urls" {
  description = "AKS OIDC Issuer URLs per cluster (for Workload Identity / Federated Credentials)"
  value       = module.aks.oidc_issuer_urls
}

output "key_vault_private_endpoint_ip" {
  description = "Key Vault Private Endpoint IP"
  value       = module.keyvault.private_endpoint_ip
}

output "phase2_command" {
  description = "Phase 2 addon 설치 시작 명령어 (Jump VM에서 실행)"
  value       = "cd ~/azure-k8s-terraform && ./addons/install.sh --cluster all"
}
