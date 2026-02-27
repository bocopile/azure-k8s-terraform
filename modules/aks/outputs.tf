output "resource_group_names" {
  description = "AKS cluster resource group names by key"
  value       = { for k, v in azurerm_resource_group.cluster : k => v.name }
}

output "cluster_ids" {
  description = "AKS cluster resource IDs by key"
  value       = { for k, v in azurerm_kubernetes_cluster.aks : k => v.id }
}

output "cluster_names" {
  description = "AKS cluster names by key"
  value       = { for k, v in azurerm_kubernetes_cluster.aks : k => v.name }
}

output "kube_configs" {
  description = "AKS kubeconfig (raw) by cluster key — sensitive"
  value       = { for k, v in azurerm_kubernetes_cluster.aks : k => v.kube_config_raw }
  sensitive   = true
}

output "oidc_issuer_urls" {
  description = "OIDC Issuer URLs for Workload Identity by cluster key"
  value       = { for k, v in azurerm_kubernetes_cluster.aks : k => v.oidc_issuer_url }
}

output "jumpbox_private_ip" {
  description = "Jump VM private IP address"
  value       = azurerm_network_interface.jumpbox.private_ip_address
}

output "bastion_dns_name" {
  description = "Azure Bastion DNS name"
  value       = azurerm_bastion_host.bastion.dns_name
}
