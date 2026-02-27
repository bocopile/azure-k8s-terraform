variable "location" {
  description = "Azure region"
  type        = string
}

variable "zones" {
  description = "Availability zones"
  type        = list(string)
}

variable "prefix" {
  description = "Naming prefix"
  type        = string
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version"
  type        = string
}

variable "vm_sizes" {
  description = "VM sizes by pool type"
  type        = map(string)
}

variable "clusters" {
  description = "Cluster definitions"
  type = map(object({
    has_ingress_pool = bool
    vnet_key         = string
  }))
}

variable "clusters_with_ingress" {
  description = "Subset of clusters that get an ingress node pool"
  type = map(object({
    has_ingress_pool = bool
    vnet_key         = string
  }))
}

variable "rg_cluster" {
  description = "Resource group name per cluster key"
  type        = map(string)
}

variable "rg_common" {
  description = "Common resource group name"
  type        = string
}

variable "subnet_ids" {
  description = "AKS subnet IDs by VNet key"
  type        = map(string)
}

variable "bastion_subnet_id" {
  description = "AzureBastionSubnet ID"
  type        = string
}

variable "jumpbox_subnet_id" {
  description = "Jumpbox subnet ID"
  type        = string
}

variable "control_plane_identity_ids" {
  description = "Control plane managed identity resource IDs by cluster key"
  type        = map(string)
}

variable "kubelet_identity_ids" {
  description = "Kubelet managed identity resource IDs by cluster key"
  type        = map(string)
}

variable "kubelet_client_ids" {
  description = "Kubelet managed identity client IDs by cluster key"
  type        = map(string)
}

variable "kubelet_object_ids" {
  description = "Kubelet managed identity object IDs by cluster key"
  type        = map(string)
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for Container Insights"
  type        = string
}

variable "monitor_workspace_id" {
  description = "Azure Monitor Workspace ID for Managed Prometheus"
  type        = string
}

variable "jumpbox_admin_username" {
  description = "Admin username for the jump VM"
  type        = string
}

variable "jumpbox_ssh_public_key" {
  description = "SSH public key for the jump VM"
  type        = string
  sensitive   = true
}

variable "jumpbox_vm_name" {
  description = "Jump VM name"
  type        = string
}

variable "jumpbox_nic_name" {
  description = "Jump VM NIC name"
  type        = string
}

variable "jumpbox_private_ip" {
  description = "Static private IP for Jump VM (must be within jumpbox subnet 10.1.1.0/24)"
  type        = string
  default     = "10.1.1.10"

  validation {
    condition     = can(cidrhost("10.1.1.0/24", 0)) && can(regex("^10\\.1\\.1\\.", var.jumpbox_private_ip))
    error_message = "jumpbox_private_ip must be within 10.1.1.0/24 (e.g. 10.1.1.10)."
  }
}

variable "bastion_name" {
  description = "Azure Bastion name"
  type        = string
}

variable "bastion_pip_name" {
  description = "Azure Bastion Public IP name"
  type        = string
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
