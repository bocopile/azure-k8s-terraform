# ============================================================
# modules/resource-group/main.tf
# Azure Resource Groups — 공통(common) + 클러스터별(cluster)
# 모든 모듈보다 먼저 생성되어 참조됨
# ============================================================

resource "azurerm_resource_group" "common" {
  name     = var.rg_common
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "cluster" {
  for_each = var.rg_cluster

  name     = each.value
  location = var.location
  tags     = var.tags
}
