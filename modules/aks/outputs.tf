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
  description = "Jump VM private IP address (null when enable_jumpbox = false)"
  value       = var.enable_jumpbox ? azurerm_network_interface.jumpbox[0].private_ip_address : null
}

output "bastion_dns_name" {
  description = "Azure Bastion DNS name (null when enable_jumpbox = false)"
  value       = var.enable_jumpbox ? azurerm_bastion_host.bastion[0].dns_name : null
}

output "bastion_host_name" {
  description = "Azure Bastion host name (null when enable_jumpbox = false)"
  value       = var.enable_jumpbox ? azurerm_bastion_host.bastion[0].name : null
}

output "jumpbox_vm_name" {
  description = "Jump VM name (null when enable_jumpbox = false)"
  value       = var.enable_jumpbox ? azurerm_linux_virtual_machine.jumpbox[0].name : null
}

output "jumpbox_identity_principal_id" {
  description = "Jump VM User-Assigned Managed Identity principal ID (null when enable_jumpbox = false)"
  value       = var.enable_jumpbox ? azurerm_user_assigned_identity.jumpbox_mi[0].principal_id : null
}
