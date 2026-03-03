output "common_resource_group_name" {
  description = "Common resource group name"
  value       = azurerm_resource_group.common.name
}

output "common_resource_group_id" {
  description = "Common resource group ID"
  value       = azurerm_resource_group.common.id
}

output "cluster_resource_group_names" {
  description = "Cluster resource group names by key"
  value       = { for k, v in azurerm_resource_group.cluster : k => v.name }
}

output "cluster_resource_group_ids" {
  description = "Cluster resource group IDs by key"
  value       = { for k, v in azurerm_resource_group.cluster : k => v.id }
}
