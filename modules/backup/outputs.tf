output "backup_vault_id" {
  description = "Backup Vault resource ID"
  value       = azurerm_data_protection_backup_vault.vault.id
}

output "backup_vault_name" {
  description = "Backup Vault name"
  value       = azurerm_data_protection_backup_vault.vault.name
}

output "backup_policy_id" {
  description = "AKS Backup Policy resource ID"
  value       = azurerm_data_protection_backup_policy_kubernetes_cluster.aks_policy.id
}
