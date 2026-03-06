# ============================================================
# modules/data-services/main.tf
# Azure Cache for Redis / MySQL Flexible Server / Service Bus
#
# 공통 패턴:
#   - 모든 서비스: Private Endpoint → snet-private-endpoints
#   - Private DNS Zone → 3개 VNet(mgmt/app1/app2) 링크
#   - Public network access: Disabled
#   - Connection String → Key Vault Secret (secrets.tf)
# ============================================================

# ============================================================
# Redis — Azure Cache for Redis (Premium)
# ============================================================

resource "azurerm_redis_cache" "redis" {
  count = var.enable_redis ? 1 : 0

  name                = var.redis_name
  location            = var.location
  resource_group_name = var.rg_common
  capacity            = var.redis_capacity
  family              = "P"
  sku_name            = "Premium"

  # Private Endpoint 구성 후 공개 접근 차단
  public_network_access_enabled = false

  # AOF 지속성 — Premium 전용, 재시작 후 데이터 복구
  redis_configuration {
    aof_backup_enabled = false
  }

  zones = ["1", "2", "3"]
  tags  = var.tags
}

resource "azurerm_private_dns_zone" "redis" {
  count = var.enable_redis ? 1 : 0

  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = var.rg_common
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  for_each = var.enable_redis ? var.vnet_ids : {}

  name                  = "dnslink-redis-${each.key}"
  resource_group_name   = var.rg_common
  private_dns_zone_name = azurerm_private_dns_zone.redis[0].name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "redis" {
  count = var.enable_redis ? 1 : 0

  name                = "pe-${var.redis_name}"
  location            = var.location
  resource_group_name = var.rg_common
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.redis_name}"
    private_connection_resource_id = azurerm_redis_cache.redis[0].id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-redis"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis[0].id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.redis]
}

# ============================================================
# MySQL — Azure Database for MySQL Flexible Server
# ============================================================

# 관리자 비밀번호 자동 생성 (random_password → Key Vault Secret)
resource "random_password" "mysql" {
  count = var.enable_mysql ? 1 : 0

  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_mysql_flexible_server" "mysql" {
  count = var.enable_mysql ? 1 : 0

  name                = var.mysql_name
  location            = var.location
  resource_group_name = var.rg_common

  administrator_login    = var.mysql_admin_username
  administrator_password = random_password.mysql[0].result

  sku_name = var.mysql_sku_name
  version  = var.mysql_version

  storage {
    size_gb           = var.mysql_storage_gb
    auto_grow_enabled = true
  }

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  # Private Endpoint 방식 — delegated_subnet_id 미사용 (기존 PE 패턴 일관성)
  # public_network_access_enabled: PE 구성 시 자동으로 false 처리됨 (provider 자동 결정)

  zone = "1"

  tags = var.tags
}

resource "azurerm_mysql_flexible_database" "db" {
  for_each = var.enable_mysql ? toset(var.mysql_databases) : toset([])

  name                = each.key
  resource_group_name = var.rg_common
  server_name         = azurerm_mysql_flexible_server.mysql[0].name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

resource "azurerm_private_dns_zone" "mysql" {
  count = var.enable_mysql ? 1 : 0

  name                = "privatelink.mysql.database.azure.com"
  resource_group_name = var.rg_common
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  for_each = var.enable_mysql ? var.vnet_ids : {}

  name                  = "dnslink-mysql-${each.key}"
  resource_group_name   = var.rg_common
  private_dns_zone_name = azurerm_private_dns_zone.mysql[0].name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "mysql" {
  count = var.enable_mysql ? 1 : 0

  name                = "pe-${var.mysql_name}"
  location            = var.location
  resource_group_name = var.rg_common
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.mysql_name}"
    private_connection_resource_id = azurerm_mysql_flexible_server.mysql[0].id
    subresource_names              = ["mysqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-mysql"
    private_dns_zone_ids = [azurerm_private_dns_zone.mysql[0].id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]
}

# ============================================================
# Service Bus — Azure Service Bus (Premium)
# RabbitMQ 대체: AMQP 1.0 호환, 완전 관리형
# ============================================================

resource "azurerm_servicebus_namespace" "sb" {
  count = var.enable_servicebus ? 1 : 0

  name                = var.servicebus_name
  location            = var.location
  resource_group_name = var.rg_common
  sku                 = "Premium"
  capacity            = var.servicebus_capacity
  # Premium SKU 필수 — 유효값: 1, 2, 4
  premium_messaging_partitions = 1

  # Private Endpoint 구성 후 공개 접근 차단
  public_network_access_enabled = false

  tags = var.tags
}

resource "azurerm_servicebus_queue" "queues" {
  for_each = var.enable_servicebus ? toset(var.servicebus_queues) : toset([])

  name         = each.key
  namespace_id = azurerm_servicebus_namespace.sb[0].id

  # 데드레터 큐 활성화 — 처리 실패 메시지 보존
  dead_lettering_on_message_expiration = true
  max_delivery_count                   = 10
  lock_duration                        = "PT1M"
}

resource "azurerm_servicebus_topic" "topics" {
  for_each = var.enable_servicebus ? toset(var.servicebus_topics) : toset([])

  name         = each.key
  namespace_id = azurerm_servicebus_namespace.sb[0].id
}

resource "azurerm_private_dns_zone" "servicebus" {
  count = var.enable_servicebus ? 1 : 0

  name                = "privatelink.servicebus.windows.net"
  resource_group_name = var.rg_common
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "servicebus" {
  for_each = var.enable_servicebus ? var.vnet_ids : {}

  name                  = "dnslink-sb-${each.key}"
  resource_group_name   = var.rg_common
  private_dns_zone_name = azurerm_private_dns_zone.servicebus[0].name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "servicebus" {
  count = var.enable_servicebus ? 1 : 0

  name                = "pe-${var.servicebus_name}"
  location            = var.location
  resource_group_name = var.rg_common
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.servicebus_name}"
    private_connection_resource_id = azurerm_servicebus_namespace.sb[0].id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-sb"
    private_dns_zone_ids = [azurerm_private_dns_zone.servicebus[0].id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.servicebus]
}
