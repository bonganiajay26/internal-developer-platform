# modules/gke — GCP equivalent of the AWS eks module.
# Decision: GKE Autopilot, not Standard. This is the single biggest structural
# difference from the AWS/Azure modules — there is no node pool resource here
# at all. Autopilot removes node provisioning, patching, and sizing entirely;
# you request pod resources and GCP schedules/bills per-pod. The trade-off
# (documented explicitly, since it reverses the AWS module's Fargate decision)
# is that Autopilot's per-pod pricing runs higher than Standard mode's raw
# node cost at sustained high utilization — the crossover point is usually
# cited around 60-70% average cluster utilization. Below that, Autopilot
# is usually cheaper AND removes an entire operational burden; above it,
# GKE Standard with manually managed node pools (same shape as the AWS
# module's node group) becomes the better trade.

variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "network_self_link" {
  type = string
}

variable "subnet_self_link" {
  type = string
}

resource "google_container_cluster" "this" {
  name     = "${var.name}-gke"
  location = var.region   # regional cluster: control plane replicated across zones in the region

  network    = var.network_self_link
  subnetwork = var.subnet_self_link

  enable_autopilot = true

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Decision: private nodes, public control-plane endpoint — same trade-off
  # as the AWS module's endpoint_public_access = true. A fully private
  # cluster (master_authorized_networks_config restricted to VPN CIDR only)
  # is the real production setting; left open here so this is reachable
  # for a portfolio demo without a VPN, and documented as such.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  # Decision: Workload Identity enabled at the cluster level — GCP's version
  # of IRSA (AWS) / Azure AD Workload Identity (Azure). Same purpose: let
  # one pod assume one specific GCP service account instead of the whole
  # node pool's broad permissions.
  workload_identity_config {
    workload_pool = "${var.name}-project.svc.id.goog"  # replace with your real project ID
  }
}

output "cluster_name"     { value = google_container_cluster.this.name }
output "cluster_endpoint" { value = google_container_cluster.this.endpoint }
output "workload_pool"    { value = "${var.name}-project.svc.id.goog" }
