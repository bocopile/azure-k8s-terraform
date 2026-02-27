output "key_vault_id" {
  description = "Key Vault resource ID"
  value       = azurerm_key_vault.kv.id
}

output "vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.kv.vault_uri
}

output "key_vault_name" {
  description = "Key Vault name"
  value       = azurerm_key_vault.kv.name
}

output "private_endpoint_ip" {
  description = "Key Vault Private Endpoint IP"
  value       = azurerm_private_endpoint.kv.private_service_connection[0].private_ip_address
}
