# Making this IDP cloud-agnostic — service mapping, Backstage hosting, and cost optimization

This repo is written for AWS. This document covers three things: (1) exactly what changes to run
the same platform on Azure or GCP, (2) what Backstage itself needs to run — which is a *separate*
question from what the platform it manages needs, and (3) concrete cost levers for the whole stack.

---

## 1. What actually changes when you switch clouds — and what doesn't

**Doesn't change:** Kubernetes API, Argo CD, Prometheus/Grafana, the microservice code, the
Dockerfile, Backstage itself. Kubernetes is the abstraction layer that makes 90% of this repo
portable — once you have a working cluster, `kubectl apply -f argocd/bootstrap/root-app.yaml`
is identical on EKS, AKS, or GKE.

**Does change:** everything in `terraform/` (the provider-specific resources that *create* the
cluster), the container registry, how CI authenticates (OIDC target changes), and how secrets are
stored. That's it — four areas, not a rewrite.

---

## 2. Full service mapping — every piece of this repo, across all three clouds

| This repo's component | AWS (current) | Azure | GCP |
|---|---|---|---|
| Terraform provider | `hashicorp/aws` | `hashicorp/azurerm` | `hashicorp/google` |
| Network | VPC (regional), `aws_subnet`, `aws_nat_gateway` | VNet (regional), Subnets, NAT Gateway | VPC (**global**, subnets are regional) |
| Managed Kubernetes | EKS (`aws_eks_cluster`) | AKS (`azurerm_kubernetes_cluster`) | GKE (`google_container_cluster`) |
| Node group | `aws_eks_node_group` | `azurerm_kubernetes_cluster_node_pool` | `google_container_node_pool` (or GKE Autopilot — no node pools to manage at all) |
| Cluster identity for nodes | IAM role (`aws_iam_role`) + 3 policy attachments | Managed Identity, assigned to the node pool | Service Account bound to the node pool |
| Pod-level cloud permissions | IRSA (IAM Roles for Service Accounts) via OIDC | Azure AD Workload Identity | Workload Identity Federation (GKE's native, simplest of the three) |
| Container registry | ECR | ACR (Azure Container Registry) | Artifact Registry (Container Registry is deprecated) |
| CI → cloud auth (no static keys) | GitHub OIDC → IAM role trust policy | GitHub OIDC → Azure AD federated credential | GitHub OIDC → Workload Identity Federation pool |
| Secrets for app/Grafana | Secrets Manager (+ External Secrets Operator) | Key Vault (+ CSI Secrets Store driver) | Secret Manager (+ External Secrets Operator) |
| Remote Terraform state | S3 + DynamoDB lock | Azure Storage Account (blob) + native state locking | GCS bucket (native locking, no separate lock table needed) |
| Load balancer for Ingress | AWS Load Balancer Controller → ALB/NLB | AGIC (App Gateway Ingress Controller) or native LB | GKE Ingress-GCE controller (built in) |
| DNS | Route 53 | Azure DNS | Cloud DNS |
| Object storage (Prometheus long-term, backups) | S3 | Blob Storage | Cloud Storage |
| Observability (native, alongside self-hosted Prometheus/Grafana) | CloudWatch | Azure Monitor | Cloud Monitoring |

**The single easiest cloud to start on for this specific stack:** GCP. GKE Autopilot removes node
group management entirely (point 2 above), Workload Identity Federation is the simplest of the
three OIDC setups, and GCS's native state locking means one fewer resource (no DynamoDB-equivalent
table) to provision before Terraform even runs. AWS remains the right choice if job-market
relevance matters more than setup simplicity — say this explicitly if asked "why AWS" in an
interview: it's a market decision, not a technical one.

---

## 3. Concrete Terraform changes to port `terraform/` to another cloud

You are **not** rewriting `envs/dev/main.tf`'s structure — you're swapping the two module
implementations underneath the same call pattern.

### Porting to Azure — what replaces `modules/vpc` and `modules/eks`

```hcl
# modules/vpc/main.tf becomes (conceptually):
resource "azurerm_resource_group" "this" { name = "${var.name}-rg"; location = var.location }
resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}
resource "azurerm_subnet" "private" {
  for_each             = var.az_map
  name                 = "${var.name}-private-${each.key}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet("10.0.0.0/16", 4, each.value)]
}
# NAT Gateway: azurerm_nat_gateway, one per subnet if replicating the per-AZ decision

# modules/eks/main.tf becomes:
resource "azurerm_kubernetes_cluster" "this" {
  name                = "${var.name}-aks"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.name
  default_node_pool {
    name       = "default"
    vm_size    = "Standard_D2s_v3"   # rough equivalent of t3.medium
    node_count = 3
    vnet_subnet_id = azurerm_subnet.private["az1"].id
  }
  identity { type = "SystemAssigned" }
}
```

**Backend block change:**
```hcl
terraform {
  backend "azurerm" {
    resource_group_name = "REPLACE_ME"
    storage_account_name = "REPLACE_ME"
    container_name       = "tfstate"
    key                  = "idp/dev/terraform.tfstate"
  }
}
```

### Porting to GCP — what replaces `modules/vpc` and `modules/eks`

```hcl
resource "google_compute_network" "this" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false   # GCP VPCs are global; subnets are regional and explicit
}
resource "google_compute_subnetwork" "private" {
  for_each      = var.regions
  name          = "${var.name}-private-${each.key}"
  network       = google_compute_network.this.id
  ip_cidr_range = each.value
  region        = each.key
}

resource "google_container_cluster" "this" {
  name     = "${var.name}-gke"
  location = var.region
  # Decision if porting here: Autopilot removes node-pool management entirely —
  # the closest GCP equivalent to "stop worrying about node patching" that AWS
  # doesn't offer without giving up DaemonSets (see original EKS module notes).
  enable_autopilot = true
}
```

**Backend block change:**
```hcl
terraform {
  backend "gcs" {
    bucket = "REPLACE_ME"
    prefix = "idp/dev"
  }
}
```

### CI/CD changes (`.github/workflows/ci-cd.yaml`)

Only the auth and registry steps change — build/test/scan stages stay identical:

| Step | AWS (current) | Azure | GCP |
|---|---|---|---|
| OIDC auth action | `aws-actions/configure-aws-credentials` | `azure/login` with federated credential | `google-github-actions/auth` |
| Registry login | `aws-actions/amazon-ecr-login` | `azure/docker-login` | `google-github-actions/auth` sets up Docker credential helper automatically |
| Registry URL pattern | `<account>.dkr.ecr.<region>.amazonaws.com` | `<registry>.azurecr.io` | `<region>-docker.pkg.dev/<project>/<repo>` |

---

## 4. What Backstage itself needs to run — a separate question from the platform it manages

This is the part that's easy to conflate: **Backstage is its own application with its own
infrastructure needs**, independent of whatever cloud the *platform* (EKS/AKS/GKE) runs on. You
could run Backstage on AWS while the cluster it manages is on GCP — the Kubernetes plugin just
needs network reachability and credentials to the cluster's API server, nothing more.

### 4.1 Backstage's own infrastructure requirements (cloud-agnostic)

| Requirement | Why Backstage needs it | Minimum viable option |
|---|---|---|
| Compute to run the Node.js app | Backstage frontend + backend are one Node process (or two, split) | A single small container/VM is enough for <50 engineers |
| PostgreSQL database | Backstage's catalog, scaffolder task history, and most plugins persist to Postgres — this is not optional beyond a demo | Managed Postgres (RDS/Azure Database for PostgreSQL/Cloud SQL) — do not self-host this for anything beyond a laptop demo |
| Object storage | TechDocs' generated static sites are published here | S3 / Blob Storage / Cloud Storage |
| Secrets store for Backstage's own credentials | Backstage needs a GitHub App token/PAT, cloud credentials for the Kubernetes plugin, and its Postgres password | Secrets Manager / Key Vault / Secret Manager — never in `app-config.yaml` directly |
| Ingress/HTTPS | Developers open this in a browser | Same load balancer pattern as any other web app on the cluster |
| Auth provider | Backstage needs to know who's logged in, to scope `OwnerPicker` and RBAC | GitHub OAuth App (simplest), or Azure AD / Google OIDC if your company already uses one for SSO |

### 4.2 Cloud-specific service list for hosting Backstage

| Piece | AWS | Azure | GCP |
|---|---|---|---|
| Run the app | ECS Fargate service, or a Deployment on the same EKS cluster it manages | Container Apps, or a Deployment on AKS | Cloud Run, or a Deployment on GKE |
| Database | RDS for PostgreSQL | Azure Database for PostgreSQL – Flexible Server | Cloud SQL for PostgreSQL |
| TechDocs storage | S3 bucket | Blob Storage container | Cloud Storage bucket |
| Secrets | Secrets Manager, injected via ECS task definition or K8s External Secrets Operator | Key Vault, injected via Container Apps secret refs or AKS CSI driver | Secret Manager, injected via Cloud Run env or GKE Workload Identity |
| Auth | GitHub OAuth App (cloud-independent) — or IAM Identity Center as a SAML/OIDC source | Entra ID (native fit — Backstage has a first-class Azure AD provider) | Google OIDC provider (native fit if your org already uses Google Workspace) |
| DNS/TLS for the portal URL | Route 53 + ACM certificate | Azure DNS + App Service Managed Certificate | Cloud DNS + Google-managed certificate |

**Recommendation for this repo specifically:** run Backstage as a Deployment inside the *same*
EKS/AKS/GKE cluster the platform already manages (it's just another workload), point it at a
managed Postgres instance (RDS/Cloud SQL/Azure Database), and use the cloud's native Secrets
service for its credentials. This avoids standing up a second piece of infrastructure (like ECS)
purely to host a portal, and means Backstage benefits from the same Argo CD GitOps deployment
pattern as everything else in this repo — you'd add `argocd/apps/backstage.yaml` pointing at a
Helm chart or manifests, exactly like `monitoring.yaml` does for kube-prometheus-stack.

### 4.3 Backstage's own required environment variables / secrets (regardless of cloud)

```
POSTGRES_HOST / POSTGRES_PASSWORD          # from your managed DB
GITHUB_TOKEN or GITHUB_APP credentials      # for repo creation (publish:github step) and catalog reads
AUTH_GITHUB_CLIENT_ID / CLIENT_SECRET       # or your SSO provider's equivalent
K8S_CLUSTER_URL + cloud auth (IRSA/Workload Identity/Managed Identity)  # for the kubernetes plugin
```

---

## 5. Cost optimization — concrete levers, in priority order

### 5.1 Compute (usually 60–70% of the bill)

| Lever | Saving | Trade-off |
|---|---|---|
| Spot/Preemptible instances for non-critical node pools | 60–90% off on-demand price | Nodes can be reclaimed with ~2 min (AWS/Azure) or 30s (GCP) notice — fine for stateless app pods behind multiple replicas, wrong for anything stateful without careful PodDisruptionBudgets |
| Right-size node instance types | 20–40% | Requires actually looking at Prometheus/Grafana CPU-memory data (this repo's own monitoring stack is the tool you'd use) rather than guessing |
| Cluster Autoscaler / Karpenter (AWS) / GKE Autopilot | Pay only for what's scheduled, not peak-provisioned capacity | Slightly slower pod scheduling during scale-up (30–90s) vs. always-on overprovisioned capacity |
| Collapse per-AZ NAT Gateways to one shared NAT in dev/staging | ~66% off NAT cost (this repo's own documented trade-off in `terraform/modules/vpc/main.tf`) | Loses the cross-AZ egress redundancy — acceptable in non-prod, not in prod |
| Reserved Instances / Savings Plans / Azure Reservations / GCP CUDs for steady-state baseline load | 30–60% off on-demand for predictable workloads | Requires 1–3 year commitment — only commit the *floor* of your usage, not peak |

### 5.2 Storage

| Lever | Saving | Trade-off |
|---|---|---|
| Prometheus retention: 10d (as configured in `monitoring/values.yaml`) instead of 30d+ locally | Smaller PVC, less cost | Longer-term queries need remote_write to Thanos/Mimir/Cortex anyway — don't pay for both long local retention *and* a long-term store |
| S3/Blob/GCS lifecycle policies — move old TechDocs builds, old Terraform state versions to cold storage after N days | 40–70% off storage for rarely-read data | Slightly slower retrieval if something old is actually needed |
| Delete unused EBS/managed-disk volumes (a very common leak: PVCs from deleted deployments don't always get reclaimed) | Pure waste elimination | None — just requires actually auditing (`kubectl get pv` for `Released` status volumes) |

### 5.3 Observability itself (ironic but real — a monitoring stack can become a cost center)

| Lever | Saving | Trade-off |
|---|---|---|
| Scrape interval 15s → 30s/60s for non-critical ServiceMonitors | Fewer stored samples, smaller Prometheus disk | Slightly coarser graphs during incident investigation |
| Drop high-cardinality labels (e.g., per-request-ID labels) before they hit Prometheus, via `metric_relabel_configs` | Can be the single biggest Prometheus cost lever — cardinality explosions are a well-known Prometheus cost failure mode | Requires knowing which labels you'll actually query on later |
| Cloud-native monitoring (CloudWatch/Azure Monitor/Cloud Monitoring) charges per-metric and per-log-GB — don't dual-ship everything to both cloud-native *and* self-hosted Prometheus | Avoids paying twice for the same signal | Cloud-native tools integrate more natively with cloud-specific alerting (e.g., auto-scaling triggers) — keep those, drop the redundant custom-metric duplication |

### 5.4 Governance — the lever most companies skip

| Lever | Saving | Trade-off |
|---|---|---|
| Mandatory tagging/labeling (`environment`, `team`, `service`) enforced via OPA/Gatekeeper policy | Makes cost *attributable* — you can't optimize what you can't see broken down by team | Adds one more admission-control check to the platform |
| Budget alerts (AWS Budgets / Azure Cost Management / GCP Budgets) at 50/80/100% of monthly forecast | Catches runaway costs (e.g., a misconfigured autoscaler) within days, not at the end of the billing cycle | None — purely additive |
| `terraform plan` cost estimation (Infracost) in CI, commented on every PR | Surfaces "this PR adds $340/month" *before* merge, not after the bill arrives | One more CI step (a few seconds) |
| Non-prod environments auto-shutdown outside business hours (scale node pools to 0 nights/weekends) | Up to ~65% off dev/staging compute (assuming a 40-hour business week) | Dev/staging unavailable outside those hours — fine for most teams, coordinate before enabling |

### 5.5 What to say in an interview when asked "how would you control platform costs"

Structure the answer in the same order as this section: **compute first** (biggest lever, spot +
right-sizing + autoscaling), **then storage** (retention and lifecycle policies), **then
observability itself** (cardinality control — most engineers don't know this is a real cost
category), **then governance** (tagging + budget alerts + cost estimation in CI, because you can't
optimize spend you can't attribute to a team). Closing with "and I'd set up Infracost in CI so cost
impact is visible in the PR, not in next month's invoice" is a strong, specific finish that most
candidates don't mention.

---

*This document assumes the same repo structure from `Repo_Complete_Explanation.md` — read that
first if you haven't, since the porting guidance above references specific files by name.*
