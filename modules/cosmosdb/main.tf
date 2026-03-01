# ============================================================
# modules/cosmosdb/main.tf
# Azure Cosmos DB (NoSQL) — Vector Search + Service Connector
#
# RAG(Retrieval-Augmented Generation) 아키텍처 지원:
#   - Cosmos DB NoSQL API + Vector Indexing Policy
#   - Private Endpoint (AKS → Cosmos DB 안전 연결)
#   - AKS Workload Identity용 RBAC 할당
# ============================================================

# ============================================================
# Cosmos DB Account — Serverless (Demo) / Provisioned (Prod)
# ============================================================

resource "azurerm_cosmosdb_account" "cosmos" {
  name                = var.account_name
  location            = var.location
  resource_group_name = var.rg_common
  offer_type          = "Standard"

  # Serverless — Demo/Dev 환경에서 비용 효율적
  kind = "GlobalDocumentDB"
  capabilities {
    name = "EnableServerless"
  }

  # Vector Search 기능 활성화
  capabilities {
    name = "EnableNoSQLVectorSearch"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }

  # 공개 접근 차단 — Private Endpoint 전용
  public_network_access_enabled     = false
  is_virtual_network_filter_enabled = false

  tags = var.tags
}

# ============================================================
# Database + Container (Vector Embedding 포함)
# ============================================================

resource "azurerm_cosmosdb_sql_database" "vectordb" {
  name                = var.database_name
  resource_group_name = var.rg_common
  account_name        = azurerm_cosmosdb_account.cosmos.name
}

resource "azurerm_cosmosdb_sql_container" "vectors" {
  name                = var.container_name
  resource_group_name = var.rg_common
  account_name        = azurerm_cosmosdb_account.cosmos.name
  database_name       = azurerm_cosmosdb_sql_database.vectordb.name
  partition_key_paths = ["/partitionKey"]

  # Vector Indexing Policy는 container 생성 후 REST/SDK로 설정
  # (azurerm provider에서 vector embedding policy 미지원)

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/*"
    }

    excluded_path {
      path = "/embedding/*"
    }
  }
}

# ============================================================
# Private Endpoint — PE 서브넷에서 Cosmos DB 접근
# ============================================================

resource "azurerm_private_endpoint" "cosmos" {
  name                = "pe-${var.account_name}"
  location            = var.location
  resource_group_name = var.rg_common
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "psc-${var.account_name}"
    private_connection_resource_id = azurerm_cosmosdb_account.cosmos.id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  # DNS 레코드 자동 관리 — PE 재생성 시 IP 변경에 안전
  private_dns_zone_group {
    name                 = "cosmos-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.cosmos.id]
  }

  tags = var.tags
}

# ============================================================
# Private DNS Zone (privatelink.documents.azure.com)
# ============================================================

resource "azurerm_private_dns_zone" "cosmos" {
  name                = "privatelink.documents.azure.com"
  resource_group_name = var.rg_common
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "cosmos" {
  for_each = var.vnet_ids

  name                  = "vnetlink-cosmos-${each.key}"
  resource_group_name   = var.rg_common
  private_dns_zone_name = azurerm_private_dns_zone.cosmos.name
  virtual_network_id    = each.value
  registration_enabled  = false
}
