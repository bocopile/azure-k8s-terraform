output "control_plane_identity_ids" {
  description = "Control plane managed identity resource IDs by cluster key"
  value       = { for k, v in azurerm_user_assigned_identity.control_plane : k => v.id }
}

output "kubelet_identity_ids" {
  description = "Kubelet managed identity resource IDs by cluster key"
  value       = { for k, v in azurerm_user_assigned_identity.kubelet : k => v.id }
}

output "kubelet_client_ids" {
  description = "Kubelet managed identity client IDs by cluster key"
  value       = { for k, v in azurerm_user_assigned_identity.kubelet : k => v.client_id }
}

output "kubelet_object_ids" {
  description = "Kubelet managed identity object IDs by cluster key"
  value       = { for k, v in azurerm_user_assigned_identity.kubelet : k => v.principal_id }
}

output "cert_manager_identity_ids" {
  description = "cert-manager managed identity resource IDs by cluster key"
  value       = { for k, v in azurerm_user_assigned_identity.cert_manager : k => v.id }
}

output "cert_manager_client_ids" {
  description = "cert-manager managed identity client IDs by cluster key"
  value       = { for k, v in azurerm_user_assigned_identity.cert_manager : k => v.client_id }
}
