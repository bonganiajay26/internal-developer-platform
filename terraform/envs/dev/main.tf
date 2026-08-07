# envs/dev — the only file you actually run `terraform apply` against.
# Decision: environments are separate root modules (not Terraform workspaces).
# Workspaces share backend state config and make it too easy to accidentally
# apply dev variables against a prod state file. Separate root modules with
# separate remote state keys make that mistake structurally impossible.

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Decision: remote state in S3 with a DynamoDB lock table. Local state
  # would work for a solo demo but breaks the moment a second engineer
  # (or CI) runs terraform at the same time — remote state + locking is
  # non-negotiable for anything beyond a personal sandbox.
  backend "s3" {
    bucket         = "REPLACE_WITH_YOUR_TF_STATE_BUCKET"
    key            = "idp/dev/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "REPLACE_WITH_YOUR_TF_LOCK_TABLE"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "platform_name" {
  type    = string
  default = "idp-dev"
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source     = "../../modules/vpc"
  name       = var.platform_name
  cidr_block = "10.0.0.0/16"
  azs        = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "eks" {
  source              = "../../modules/eks"
  name                = var.platform_name
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_types = ["t3.medium"]
  node_min_size       = 2
  node_max_size       = 6
  node_desired_size   = 3
}

output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
