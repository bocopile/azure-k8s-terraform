# ============================================================
# modules/data-services/outputs.tf
# ============================================================

# ---- Redis ----

output "redis_hostname" {
  description = "Redis Private Endpoint 경유 hostname"
  value       = var.enable_redis ? azurerm_redis_cache.redis[0].hostname : null
}

output "redis_port" {
  description = "Redis SSL port"
  value       = var.enable_redis ? azurerm_redis_cache.redis[0].ssl_port : null
}

output "redis_id" {
  description = "Redis resource ID"
  value       = var.enable_redis ? azurerm_redis_cache.redis[0].id : null
}

# ---- MySQL ----

output "mysql_fqdn" {
  description = "MySQL Flexible Server FQDN (Private Endpoint 경유)"
  value       = var.enable_mysql ? azurerm_mysql_flexible_server.mysql[0].fqdn : null
}

output "mysql_id" {
  description = "MySQL Flexible Server resource ID"
  value       = var.enable_mysql ? azurerm_mysql_flexible_server.mysql[0].id : null
}

# ---- Service Bus ----

output "servicebus_namespace" {
  description = "Service Bus Namespace 이름"
  value       = var.enable_servicebus ? azurerm_servicebus_namespace.sb[0].name : null
}

output "servicebus_endpoint" {
  description = "Service Bus AMQP endpoint"
  value       = var.enable_servicebus ? "sb://${azurerm_servicebus_namespace.sb[0].name}.servicebus.windows.net/" : null
}

output "servicebus_id" {
  description = "Service Bus Namespace resource ID"
  value       = var.enable_servicebus ? azurerm_servicebus_namespace.sb[0].id : null
}
