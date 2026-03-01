output "common_resource_group_name" {
  description = "Common resource group name"
  value       = azurerm_resource_group.common.name
}

output "common_resource_group_id" {
  description = "Common resource group ID"
  value       = azurerm_resource_group.common.id
}

output "vnet_ids" {
  description = "VNet resource IDs by key"
  value       = { for k, v in azurerm_virtual_network.vnet : k => v.id }
}

output "vnet_names" {
  description = "VNet names by key"
  value       = { for k, v in azurerm_virtual_network.vnet : k => v.name }
}

output "aks_subnet_ids" {
  description = "AKS subnet IDs by VNet key"
  value       = { for k, v in azurerm_subnet.aks : k => v.id }
}

output "bastion_subnet_id" {
  description = "AzureBastionSubnet ID"
  value       = azurerm_subnet.bastion.id
}

output "jumpbox_subnet_id" {
  description = "Jumpbox subnet ID"
  value       = azurerm_subnet.jumpbox.id
}

output "pe_subnet_id" {
  description = "Private Endpoint subnet ID (mgmt VNet)"
  value       = azurerm_subnet.private_endpoint.id
}

output "nsg_aks_ids" {
  description = "AKS NSG resource IDs by VNet key"
  value       = { for k, v in azurerm_network_security_group.aks : k => v.id }
}

output "aks_private_dns_zone_id" {
  description = "AKS Private Cluster shared DNS Zone ID"
  value       = azurerm_private_dns_zone.aks.id
}
