# ============================================================
# flow-logs.tf — NSG Flow Logs + Network Watcher + Traffic Analytics
#
# 루트 레벨 배치 이유:
#   Network Watcher Flow Log는 network 모듈(NSG)과 monitoring 모듈(LAW)
#   양쪽 output을 참조 → 순환 의존 방지를 위해 root에 배치
#
# 구성:
#   - Network Watcher (리전당 1개)
#   - Storage Account (Flow Log 원본 저장, 30일 보존)
#   - NSG Flow Log (AKS 서브넷 NSG × 3개 VNet)
#   - Traffic Analytics → LAW 연동 (10분 간격)
# ============================================================

resource "azurerm_network_watcher" "nw" {
  name                = "nw-${local.location}"
  location            = local.location
  resource_group_name = module.network.common_resource_group_name
  tags                = var.tags
}

resource "azurerm_storage_account" "flow_logs" {
  name                            = local.names.flow_log_storage
  location                        = local.location
  resource_group_name             = module.network.common_resource_group_name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                   = "TLS1_2"
  infrastructure_encryption_enabled = true
  tags                            = var.tags
}

resource "azurerm_network_watcher_flow_log" "aks" {
  for_each = local.vnets

  name                 = "flowlog-nsg-aks-${each.key}"
  network_watcher_name = azurerm_network_watcher.nw.name
  resource_group_name  = module.network.common_resource_group_name

  network_security_group_id = module.network.nsg_aks_ids[each.key]
  storage_account_id        = azurerm_storage_account.flow_logs.id
  enabled                   = true
  version                   = 2

  retention_policy {
    enabled = true
    days    = 30
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = module.monitoring.log_analytics_workspace_guid
    workspace_region      = local.location
    workspace_resource_id = module.monitoring.log_analytics_workspace_id
    interval_in_minutes   = 10
  }
}
