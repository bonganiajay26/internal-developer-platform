# modules/network — Azure equivalent of the AWS vpc module.
# Decision: Azure VNets are regional (like AWS VPCs, unlike GCP's global VPC),
# so the AZ-spreading pattern from the AWS module carries over almost exactly —
# we spread subnets across Availability Zones within one region.

variable "name" {
  type = string
}

variable "location" {
  type    = string
  default = "centralindia"
}

variable "address_space" {
  type    = string
  default = "10.1.0.0/16"
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name}-rg"
  location = var.location
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  address_space       = [var.address_space]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

# Decision: a single subnet for AKS nodes (Azure CNI hands each pod a real
# VNet IP, so the subnet needs to be sized generously — /20 gives ~4000 IPs,
# comfortably covering nodes + pods for a dev cluster without a redesign later).
resource "azurerm_subnet" "aks" {
  name                 = "${var.name}-aks-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.1.0.0/20"]
}

# Decision: Network Security Group at the subnet level, not per-NIC — simpler
# to reason about and audit than per-node rules, at the cost of coarser control
# if two very different workloads ever need different network policies (solved
# later with Kubernetes NetworkPolicies inside the cluster instead, if needed).
resource "azurerm_network_security_group" "aks" {
  name                = "${var.name}-aks-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

output "resource_group_name" { value = azurerm_resource_group.this.name }
output "location"            { value = azurerm_resource_group.this.location }
output "subnet_id"           { value = azurerm_subnet.aks.id }
output "vnet_id"             { value = azurerm_virtual_network.this.id }
