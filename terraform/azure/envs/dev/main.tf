# envs/dev — Azure root module. Same shape as terraform/aws/envs/dev/main.tf
# on purpose — the module composition pattern is identical across clouds;
# only the resources inside modules/network and modules/aks differ.

terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  # Decision: Azure Storage Account backend has native state locking built in
  # (via blob leases) — unlike AWS, there's no separate DynamoDB-equivalent
  # table to provision first. One less piece of bootstrap infrastructure.
  backend "azurerm" {
    resource_group_name  = "REPLACE_WITH_YOUR_TFSTATE_RG"
    storage_account_name = "REPLACE_WITH_YOUR_STORAGE_ACCOUNT"
    container_name        = "tfstate"
    key                    = "idp/dev/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

variable "platform_name" {
  type    = string
  default = "idp-dev"
}

variable "location" {
  type    = string
  default = "centralindia"
}

module "network" {
  source   = "../../modules/network"
  name     = var.platform_name
  location = var.location
}

module "aks" {
  source               = "../../modules/aks"
  name                 = var.platform_name
  resource_group_name  = module.network.resource_group_name
  location             = module.network.location
  subnet_id            = module.network.subnet_id
}

output "cluster_name" { value = module.aks.cluster_name }
output "configure_kubectl" {
  value = "az aks get-credentials --resource-group ${module.network.resource_group_name} --name ${module.aks.cluster_name}"
}
