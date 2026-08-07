# envs/dev — GCP root module. Same composition pattern as the AWS and Azure
# envs/dev files — only the resources inside modules/network and modules/gke
# differ per cloud.

terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }

  # Decision: GCS backend has native state locking (no separate lock table,
  # like Azure and unlike AWS) — the simplest of the three backends to bootstrap.
  backend "gcs" {
    bucket = "REPLACE_WITH_YOUR_TFSTATE_BUCKET"
    prefix = "idp/dev"
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "platform_name" {
  type    = string
  default = "idp-dev"
}

module "network" {
  source = "../../modules/network"
  name   = var.platform_name
  region = var.region
}

module "gke" {
  source             = "../../modules/gke"
  name               = var.platform_name
  region             = var.region
  network_self_link  = module.network.network_self_link
  subnet_self_link   = module.network.subnet_self_link
}

output "cluster_name" { value = module.gke.cluster_name }
output "configure_kubectl" {
  value = "gcloud container clusters get-credentials ${module.gke.cluster_name} --region ${var.region} --project ${var.project_id}"
}
