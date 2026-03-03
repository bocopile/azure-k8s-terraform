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

output "bastion_host_name" {
  description = "Azure Bastion host name"
  value       = azurerm_bastion_host.bastion.name
}

output "jumpbox_vm_name" {
  description = "Jump VM name"
  value       = azurerm_linux_virtual_machine.jumpbox.name
}
