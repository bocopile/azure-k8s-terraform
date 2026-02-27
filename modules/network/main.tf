# ============================================================
# modules/network/main.tf
# VNets, Subnets, NSGs, VNet Peering (full mesh)
# ============================================================

# --- Common resource group (shared infra) ---
resource "azurerm_resource_group" "common" {
  name     = var.rg_common
  location = var.location
  tags     = var.tags
}

# ============================================================
# Virtual Networks
# ============================================================

resource "azurerm_virtual_network" "vnet" {
  for_each = var.vnets

  name                = "vnet-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.common.name
  address_space       = [each.value.cidr]
  tags                = var.tags
}

# ============================================================
# Subnets — AKS (all VNets)
# ============================================================

resource "azurerm_subnet" "aks" {
  for_each = var.vnets

  name                 = "snet-aks-${each.key}"
  resource_group_name  = azurerm_resource_group.common.name
  virtual_network_name = azurerm_virtual_network.vnet[each.key].name
  address_prefixes     = [var.aks_subnets[each.key]]
}

# ============================================================
# Subnets — mgmt VNet only (Bastion + Jumpbox)
# ============================================================

# Azure requires exactly "AzureBastionSubnet" as the name
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.common.name
  virtual_network_name = azurerm_virtual_network.vnet["mgmt"].name
  address_prefixes     = [var.bastion_subnet_cidr]
}

resource "azurerm_subnet" "jumpbox" {
  name                 = "snet-jumpbox"
  resource_group_name  = azurerm_resource_group.common.name
  virtual_network_name = azurerm_virtual_network.vnet["mgmt"].name
  address_prefixes     = [var.jumpbox_subnet_cidr]
}

# Private Endpoint 전용 서브넷 (Key Vault, Monitor Workspace 등)
# Private Endpoint 서브넷에는 NSG 적용하지 않음 (Azure 권장)
resource "azurerm_subnet" "private_endpoint" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.common.name
  virtual_network_name = azurerm_virtual_network.vnet["mgmt"].name
  address_prefixes     = [var.pe_subnet_cidr]
}

# ============================================================
# Network Security Groups
# ============================================================

resource "azurerm_network_security_group" "aks" {
  for_each = var.vnets

  name                = "nsg-aks-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.common.name
  tags                = var.tags

  # Allow AKS control plane inbound (required for managed AKS)
  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Allow intra-VNet communication
  security_rule {
    name                       = "AllowVnetInboundTraffic"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # Deny all other inbound
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Bastion NSG — Azure Bastion required rules
resource "azurerm_network_security_group" "bastion" {
  name                = "nsg-bastion"
  location            = var.location
  resource_group_name = azurerm_resource_group.common.name
  tags                = var.tags

  # Required inbound: HTTPS from Internet
  security_rule {
    name                       = "AllowHttpsInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Required inbound: Gateway Manager
  security_rule {
    name                       = "AllowGatewayManagerInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  # Required inbound: Azure Load Balancer
  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Required inbound: BastionHostCommunication
  security_rule {
    name                       = "AllowBastionHostCommunicationInbound"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # Required outbound: SSH/RDP to VMs
  security_rule {
    name                       = "AllowSshRdpOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }

  # Required outbound: Azure Cloud
  security_rule {
    name                       = "AllowAzureCloudOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureCloud"
  }

  # Required outbound: BastionHostCommunication
  security_rule {
    name                       = "AllowBastionHostCommunicationOutbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

# Jumpbox NSG
resource "azurerm_network_security_group" "jumpbox" {
  name                = "nsg-jumpbox"
  location            = var.location
  resource_group_name = azurerm_resource_group.common.name
  tags                = var.tags

  # Allow SSH from Bastion subnet only
  security_rule {
    name                       = "AllowSshFromBastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.bastion_subnet_cidr
    destination_address_prefix = "*"
  }

  # Deny all other inbound
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# ============================================================
# NSG Associations
# ============================================================

resource "azurerm_subnet_network_security_group_association" "aks" {
  for_each = var.vnets

  subnet_id                 = azurerm_subnet.aks[each.key].id
  network_security_group_id = azurerm_network_security_group.aks[each.key].id
}

resource "azurerm_subnet_network_security_group_association" "bastion" {
  subnet_id                 = azurerm_subnet.bastion.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

resource "azurerm_subnet_network_security_group_association" "jumpbox" {
  subnet_id                 = azurerm_subnet.jumpbox.id
  network_security_group_id = azurerm_network_security_group.jumpbox.id
}

# ============================================================
# VNet Peering — Full mesh (mgmt↔app1, mgmt↔app2, app1↔app2)
# ============================================================

locals {
  # Generate all ordered pairs for full-mesh peering
  peering_pairs = {
    "mgmt-to-app1" = { src = "mgmt", dst = "app1" }
    "app1-to-mgmt" = { src = "app1", dst = "mgmt" }
    "mgmt-to-app2" = { src = "mgmt", dst = "app2" }
    "app2-to-mgmt" = { src = "app2", dst = "mgmt" }
    "app1-to-app2" = { src = "app1", dst = "app2" }
    "app2-to-app1" = { src = "app2", dst = "app1" }
  }
}

resource "azurerm_virtual_network_peering" "mesh" {
  for_each = local.peering_pairs

  name                      = "peer-${each.key}"
  resource_group_name       = azurerm_resource_group.common.name
  virtual_network_name      = azurerm_virtual_network.vnet[each.value.src].name
  remote_virtual_network_id = azurerm_virtual_network.vnet[each.value.dst].id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
