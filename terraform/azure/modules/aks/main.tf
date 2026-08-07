# modules/aks — Azure equivalent of the AWS eks module.
# Decision: SystemAssigned managed identity for the cluster (not a manually
# created service principal). Managed identity means no credential to rotate
# or leak — Azure handles the identity lifecycle tied to the resource itself.
# This is a strictly better default than AWS's IAM-role-per-cluster pattern
# required manual setup for; Azure gives you this for free.

variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "node_vm_size" {
  type    = string
  default = "Standard_D2s_v3"   # ~2 vCPU / 8GB — rough equivalent of AWS t3.medium
}

variable "node_min_count" {
  type    = number
  default = 2
}

variable "node_max_count" {
  type    = number
  default = 6
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name                = "default"
    vm_size             = var.node_vm_size
    vnet_subnet_id      = var.subnet_id
    auto_scaling_enabled = true
    min_count           = var.node_min_count
    max_count           = var.node_max_count
    # Decision: 3 zones, mirroring the AWS module's 3-AZ spread — a single
    # zone outage doesn't take the whole node pool with it.
    zones = ["1", "2", "3"]
  }

  identity {
    type = "SystemAssigned"
  }

  # Decision: Azure CNI (not kubenet). Azure CNI gives every pod a routable
  # VNet IP, which is what lets Azure-native tools (App Gateway Ingress
  # Controller, Azure Monitor for Containers) talk to pods directly without
  # an extra NAT hop — the trade-off is it consumes far more subnet IP space
  # than kubenet, which is why modules/network sizes the subnet at /20.
  network_profile {
    network_plugin = "azure"
    load_balancer_sku = "standard"
  }

  # Decision: Azure AD Workload Identity enabled at the cluster level. This is
  # the direct equivalent of AWS's IRSA (IAM Roles for Service Accounts) —
  # it's what lets a single pod (e.g. External Secrets Operator) assume a
  # specific Azure identity instead of inheriting the whole node pool's
  # permissions, without this the node's managed identity would need every
  # permission any pod on it might ever need — a real security gap otherwise.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
}

output "cluster_name" { value = azurerm_kubernetes_cluster.this.name }

output "kube_config" {
  value     = azurerm_kubernetes_cluster.this.kube_config_raw
  sensitive = true
}

output "oidc_issuer_url"  { value = azurerm_kubernetes_cluster.this.oidc_issuer_url }
output "cluster_identity" { value = azurerm_kubernetes_cluster.this.identity[0].principal_id }
