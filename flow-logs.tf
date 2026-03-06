# ============================================================
# flow-logs.tf — VNet Flow Logs + Network Watcher + Traffic Analytics
#
# 루트 레벨 배치 이유:
#   Network Watcher Flow Log는 network 모듈(VNet)과 monitoring 모듈(LAW)
#   양쪽 output을 참조 → 순환 의존 방지를 위해 root에 배치
#
# 구성:
#   - Network Watcher (리전당 1개)
#   - Storage Account (Flow Log 원본 저장, 30일 보존)
#   - VNet Flow Log (AKS VNet × 3개)
#   - Traffic Analytics → LAW 연동 (10분 간격)
#
# 참고: NSG Flow Logs는 2025-06-30부로 신규 생성 불가 (Azure 정책)
#       VNet Flow Logs로 마이그레이션 완료
# ============================================================

resource "azurerm_network_watcher" "nw" {
  name                = "nw-${local.prefix}"
  location            = local.location
  resource_group_name = module.resource_group.common_resource_group_name
  tags                = var.tags

}

resource "azurerm_storage_account" "flow_logs" {
  name                              = local.names.flow_log_storage
  location                          = local.location
  resource_group_name               = module.resource_group.common_resource_group_name
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  min_tls_version                   = "TLS1_2"
  infrastructure_encryption_enabled = true
  allow_nested_items_to_be_public   = false
  tags                              = var.tags
}

resource "azurerm_network_watcher_flow_log" "vnet" {
  for_each = local.vnets

  name                 = "flowlog-vnet-${each.key}"
  network_watcher_name = azurerm_network_watcher.nw.name
  resource_group_name  = module.resource_group.common_resource_group_name

  target_resource_id = module.network.vnet_ids[each.key]
  storage_account_id = azurerm_storage_account.flow_logs.id
  enabled            = true
  version            = 2

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = module.monitoring.log_analytics_workspace_guid
    workspace_region      = local.location
    workspace_resource_id = module.monitoring.log_analytics_workspace_id
    interval_in_minutes   = 10
  }
}
