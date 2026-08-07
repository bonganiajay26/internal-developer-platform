# modules/network — GCP equivalent of the AWS vpc module.
# Decision: GCP VPCs are GLOBAL (unlike AWS/Azure's regional VPCs) — one VPC
# resource, with regional subnets inside it. This is a genuine conceptual
# difference worth stating in an interview: on GCP you don't design "one VPC
# per region," you design "one subnet per region inside one VPC."

variable "name" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

resource "google_compute_network" "this" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false   # explicit subnets, not GCP's default auto-mode
}

# Decision: a single regional subnet with two secondary IP ranges — one for
# pod IPs, one for service IPs. This is GKE's VPC-native (alias IP) mode,
# the modern default: pods get real routable VPC IPs instead of an overlay
# network, which is what lets GCP-native tools (Cloud Armor, VPC firewall
# rules) apply directly to pod traffic, same benefit Azure CNI gives on AKS.
resource "google_compute_subnetwork" "private" {
  name          = "${var.name}-private"
  ip_cidr_range = "10.2.0.0/20"
  region        = var.region
  network       = google_compute_network.this.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.4.0.0/14"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.8.0.0/20"
  }

  private_ip_google_access = true
}

# Decision: Cloud NAT + Cloud Router so GKE nodes (which get no public IPs
# in a private cluster) can still reach the internet for image pulls — the
# direct GCP equivalent of the AWS module's per-AZ NAT Gateways, but GCP's
# NAT is regional by default rather than per-zone, so this is one resource
# instead of three — cheaper by construction, not by a conscious trade-off.
resource "google_compute_router" "this" {
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name                               = "${var.name}-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

output "network_self_link"    { value = google_compute_network.this.self_link }
output "subnet_self_link"     { value = google_compute_subnetwork.private.self_link }
output "pods_range_name"      { value = "pods" }
output "services_range_name"  { value = "services" }
