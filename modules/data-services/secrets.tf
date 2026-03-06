# ============================================================
# modules/data-services/secrets.tf
# Connection String / 비밀번호 → Key Vault Secret 저장
# 앱에서 KV 참조로 Connection String 주입 (Workload Identity)
# ============================================================

# ---- Redis ----

resource "azurerm_key_vault_secret" "redis_connection_string" {
  count = var.enable_redis ? 1 : 0

  name         = "redis-connection-string"
  value        = azurerm_redis_cache.redis[0].primary_connection_string
  key_vault_id = var.key_vault_id

  tags = var.tags

  depends_on = [azurerm_redis_cache.redis]
}

resource "azurerm_key_vault_secret" "redis_host" {
  count = var.enable_redis ? 1 : 0

  name         = "redis-host"
  value        = azurerm_redis_cache.redis[0].hostname
  key_vault_id = var.key_vault_id

  tags = var.tags
}

resource "azurerm_key_vault_secret" "redis_password" {
  count = var.enable_redis ? 1 : 0

  name         = "redis-primary-key"
  value        = azurerm_redis_cache.redis[0].primary_access_key
  key_vault_id = var.key_vault_id

  tags = var.tags
}

# ---- MySQL ----

resource "azurerm_key_vault_secret" "mysql_password" {
  count = var.enable_mysql ? 1 : 0

  name         = "mysql-admin-password"
  value        = random_password.mysql[0].result
  key_vault_id = var.key_vault_id

  tags = var.tags

  depends_on = [random_password.mysql]
}

resource "azurerm_key_vault_secret" "mysql_connection_string" {
  count = var.enable_mysql ? 1 : 0

  name  = "mysql-connection-string"
  value = "Server=${azurerm_mysql_flexible_server.mysql[0].fqdn};Port=3306;User Id=${var.mysql_admin_username};Password=${random_password.mysql[0].result};SslMode=Required;"
  key_vault_id = var.key_vault_id

  tags = var.tags

  depends_on = [azurerm_mysql_flexible_server.mysql, random_password.mysql]
}

# ---- Service Bus ----

resource "azurerm_servicebus_namespace_authorization_rule" "apps" {
  count = var.enable_servicebus ? 1 : 0

  name         = "apps-rule"
  namespace_id = azurerm_servicebus_namespace.sb[0].id

  listen = true
  send   = true
  manage = false
}

resource "azurerm_key_vault_secret" "servicebus_connection_string" {
  count = var.enable_servicebus ? 1 : 0

  name         = "servicebus-connection-string"
  value        = azurerm_servicebus_namespace_authorization_rule.apps[0].primary_connection_string
  key_vault_id = var.key_vault_id

  tags = var.tags

  depends_on = [azurerm_servicebus_namespace_authorization_rule.apps]
}

resource "azurerm_key_vault_secret" "servicebus_endpoint" {
  count = var.enable_servicebus ? 1 : 0

  name         = "servicebus-endpoint"
  value        = "sb://${azurerm_servicebus_namespace.sb[0].name}.servicebus.windows.net/"
  key_vault_id = var.key_vault_id

  tags = var.tags
}
