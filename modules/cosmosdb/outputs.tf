output "account_id" {
  description = "Cosmos DB account resource ID"
  value       = azurerm_cosmosdb_account.cosmos.id
}

output "account_endpoint" {
  description = "Cosmos DB account endpoint"
  value       = azurerm_cosmosdb_account.cosmos.endpoint
}

output "database_name" {
  description = "Cosmos DB database name"
  value       = azurerm_cosmosdb_sql_database.vectordb.name
}

output "container_name" {
  description = "Cosmos DB container name"
  value       = azurerm_cosmosdb_sql_container.vectors.name
}
