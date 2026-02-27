output "acr_id" {
  description = "ACR resource ID"
  value       = azurerm_container_registry.acr.id
}

output "login_server" {
  description = "ACR login server URL"
  value       = azurerm_container_registry.acr.login_server
}

output "acr_name" {
  description = "ACR name"
  value       = azurerm_container_registry.acr.name
}
