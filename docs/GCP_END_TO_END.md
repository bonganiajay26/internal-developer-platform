# GCP — End-to-end implementation guide

Everything you need to go from zero to a fully running platform on GCP: prerequisites, exact
services used, and every command in order. No step skipped.

---

## 1. Services used (complete list)

| Service | Role in this platform |
|---|---|
| VPC (global), Subnetwork, Cloud Router, Cloud NAT | Networking layer (`terraform/gcp/modules/network`) |
| GKE Autopilot | Managed Kubernetes — no node pools to manage at all (`terraform/gcp/modules/gke`) |
| Workload Identity | Pod-level GCP permissions (equivalent of AWS IRSA / Azure AD Workload Identity) |
| Artifact Registry | Stores the microservice's Docker images |
| Cloud Storage (GCS) | Terraform remote state (native locking, no separate lock table needed) |
| Secret Manager | Grafana admin password, Backstage's GitHub token, DB credentials |
| Cloud SQL for PostgreSQL | Backstage's catalog/scaffolder database (if hosting Backstage on GCP) |
| Cloud DNS (optional) | DNS for the Backstage portal URL, if using a real domain |
| Cloud Monitoring (optional) | Native GCP monitoring, alongside self-hosted Prometheus/Grafana |

## 2. Prerequisites

- A GCP project with billing enabled and a budget alert configured
- Installed locally: `gcloud` CLI, `terraform` >= 1.7, `kubectl`, `helm`, `docker`
- `gcloud auth login` completed, and the right project selected (`gcloud config set project YOUR_PROJECT_ID`)
- Enable required APIs once: `gcloud services enable container.googleapis.com artifactregistry.googleapis.com sqladmin.googleapis.com`

## 3. End-to-end steps

### Step 1 — Bootstrap Terraform remote state (one-time, manual)

```bash
gcloud storage buckets create gs://YOUR_TF_STATE_BUCKET --location=asia-south1
gcloud storage buckets update gs://YOUR_TF_STATE_BUCKET --versioning
```

Edit `terraform/gcp/envs/dev/main.tf`'s `backend "gcs" {}` block with this bucket name. No separate
lock table needed — GCS backend locking is native, the simplest of the three clouds' backends to
bootstrap.

### Step 2 — Provision the network and cluster

```bash
cd terraform/gcp/envs/dev
terraform init
terraform plan -var="project_id=YOUR_PROJECT_ID"
terraform apply -var="project_id=YOUR_PROJECT_ID"
```

This creates: 1 global VPC, 1 regional subnet with pod/service secondary ranges, 1 Cloud Router +
Cloud NAT, 1 GKE Autopilot cluster. Takes roughly 8–10 minutes — Autopilot clusters typically
provision faster than Standard mode since there's no node pool to bring up separately.

### Step 3 — Point kubectl at the new cluster

```bash
gcloud container clusters get-credentials idp-dev-gke --region asia-south1 --project YOUR_PROJECT_ID
kubectl get nodes    # Autopilot provisions nodes on-demand as pods are scheduled — may show 0 until step 6
```

### Step 4 — Create the Artifact Registry repository

```bash
gcloud artifacts repositories create sample-service-repo \
  --repository-format=docker --location=asia-south1
```

### Step 5 — Set up Workload Identity Federation for GitHub Actions (no JSON key file)

```bash
# 1. Create a Workload Identity Pool and Provider (one-time per project)
gcloud iam workload-identity-pools create "github-pool" --location="global"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --location="global" --workload-identity-pool="github-pool" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='YOUR_USERNAME/internal-developer-platform'"

# 2. Create a service account and bind it to the pool
gcloud iam service-accounts create github-actions-sa
gcloud iam service-accounts add-iam-policy-binding \
  github-actions-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/YOUR_PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/attribute.repository/YOUR_USERNAME/internal-developer-platform"

# 3. Grant the service account push rights to Artifact Registry
gcloud artifacts repositories add-iam-policy-binding sample-service-repo \
  --location=asia-south1 \
  --member="serviceAccount:github-actions-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"
```

Add `GCP_WORKLOAD_IDENTITY_PROVIDER` (the full provider resource name) and `GCP_SERVICE_ACCOUNT`
as GitHub repo secrets.

### Step 6 — Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/bootstrap/root-app.yaml
kubectl get applications -n argocd
```

### Step 7 — Push code and let the pipeline run

```bash
git add .
git commit -m "Initial platform deploy (GCP)"
git push
```

`ci-cd-gcp.yaml` runs → tests → builds → Trivy scans → pushes to Artifact Registry → commits the
new image tag → Argo CD syncs.

### Step 8 — Verify

```bash
kubectl get pods -n apps
kubectl get pods -n monitoring
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

**Autopilot-specific note:** the `resources.requests` values in `app/k8s/deployment.yaml` directly
determine your bill on Autopilot (you're charged per-pod-resource-request, not per-node) — this is
worth stating explicitly if asked how GKE Autopilot billing differs from the AWS/Azure model.

### Step 9 (optional) — Host Backstage on this same cluster

```bash
gcloud sql instances create backstage-db --database-version=POSTGRES_15 \
  --tier=db-f1-micro --region=asia-south1
gcloud sql users set-password postgres --instance=backstage-db --password=CHANGE_ME
# then deploy Backstage as another Argo CD Application, using the Cloud SQL
# Auth Proxy sidecar (or private IP) to connect from within the cluster
```

### Step 10 — Tear down

```bash
kubectl delete -f argocd/bootstrap/root-app.yaml
cd terraform/gcp/envs/dev
terraform destroy -var="project_id=YOUR_PROJECT_ID"
```

---

## What this costs, roughly (asia-south1, dev-sized, running 24/7)

| Item | Approx. monthly cost |
|---|---|
| GKE Autopilot management fee | Free for the first zonal cluster per billing account; ~$73/mo per cluster after that (regional clusters like this one are billed) |
| Pod compute (sample-service: 2 pods × 50m/64Mi requests, monitoring stack: ~500m/1Gi) | ~$40-60, scales with actual requested resources, not node capacity |
| Cloud NAT | ~$32 (single regional NAT, cheaper by construction than AWS's per-AZ pattern) |
| Persistent disks (Prometheus + Grafana PVCs) | ~$3 |
| **Total** | **~$150-170/month** |

Autopilot's per-pod billing model tends to be the cheapest of the three clouds at this dev/demo
scale specifically because you're not paying for whole-node capacity sitting idle — worth
mentioning as a genuine, non-generic cost comparison point.
