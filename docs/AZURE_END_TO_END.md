# Azure — End-to-end implementation guide

Everything you need to go from zero to a fully running platform on Azure: prerequisites, exact
services used, and every command in order. No step skipped.

---

## 1. Services used (complete list)

| Service | Role in this platform |
|---|---|
| Resource Group | Logical container for every resource this platform creates |
| Virtual Network, Subnet, NSG | Networking layer (`terraform/azure/modules/network`) |
| AKS (Azure Kubernetes Service) | Managed Kubernetes control plane + node pool (`terraform/azure/modules/aks`) |
| Managed Identity | Cluster and node pool identity — no service principal credential to manage |
| Azure AD Workload Identity | Pod-level Azure permissions (equivalent of AWS IRSA) |
| ACR (Azure Container Registry) | Stores the microservice's Docker images |
| Azure Storage Account (Blob) | Terraform remote state (with native locking — no separate lock table needed) |
| Key Vault | Grafana admin password, Backstage's GitHub token, DB credentials |
| Azure Database for PostgreSQL – Flexible Server | Backstage's catalog/scaffolder database (if hosting Backstage on Azure) |
| Azure DNS (optional) | DNS for the Backstage portal URL, if using a real domain |
| Azure Monitor (optional) | Native Azure monitoring, alongside self-hosted Prometheus/Grafana |

## 2. Prerequisites

- An Azure subscription with a spending limit or budget alert configured
- Installed locally: `az` CLI, `terraform` >= 1.7, `kubectl`, `helm`, `docker`
- A GitHub repository this code is pushed to (for the CI/CD steps)
- `az login` completed, and the right subscription selected (`az account set --subscription "..."`)

## 3. End-to-end steps

### Step 1 — Bootstrap Terraform remote state (one-time, manual)

```bash
az group create --name tfstate-rg --location centralindia
az storage account create --name YOUR_STORAGE_ACCOUNT --resource-group tfstate-rg \
  --location centralindia --sku Standard_LRS --encryption-services blob
az storage container create --name tfstate --account-name YOUR_STORAGE_ACCOUNT
```

Edit `terraform/azure/envs/dev/main.tf`'s `backend "azurerm" {}` block with these exact names.
Note: unlike AWS, there's no separate lock-table resource to create — Azure Storage handles
state locking natively via blob leases.

### Step 2 — Provision the network and cluster

```bash
cd terraform/azure/envs/dev
terraform init
terraform plan
terraform apply
```

This creates: 1 Resource Group, 1 VNet + subnet + NSG, 1 AKS cluster with a 2–6 node autoscaling
pool spread across 3 zones. Takes roughly 8–12 minutes.

### Step 3 — Point kubectl at the new cluster

```bash
az aks get-credentials --resource-group idp-dev-rg --name idp-dev-aks
kubectl get nodes
```

### Step 4 — Create the Azure Container Registry

```bash
az acr create --resource-group idp-dev-rg --name YOURACRNAME --sku Basic
az aks update --resource-group idp-dev-rg --name idp-dev-aks --attach-acr YOURACRNAME
```

`--attach-acr` grants the AKS cluster's identity `AcrPull` automatically — no manual role
assignment needed for nodes to pull images.

### Step 5 — Set up GitHub OIDC federation into Azure (no client secret)

```bash
# 1. Create an Azure AD App Registration
az ad app create --display-name "github-actions-idp"
APP_ID=$(az ad app list --display-name "github-actions-idp" --query "[0].appId" -o tsv)

# 2. Create a federated credential scoped to your exact repo + branch
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-main-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:YOUR_USERNAME/internal-developer-platform:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

# 3. Create a service principal for the app, and grant it ACR push rights
az ad sp create --id $APP_ID
az role assignment create --assignee $APP_ID --role AcrPush \
  --scope $(az acr show --name YOURACRNAME --query id -o tsv)
```

Add `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` as GitHub repo secrets — no
client secret needed, since federated credentials replace it entirely.

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
git commit -m "Initial platform deploy (Azure)"
git push
```

`ci-cd-azure.yaml` runs → tests → builds → Trivy scans → pushes to ACR → commits the new image
tag → Argo CD syncs.

### Step 8 — Verify

```bash
kubectl get pods -n apps
kubectl get pods -n monitoring
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

### Step 9 (optional) — Host Backstage on this same cluster

```bash
az postgres flexible-server create --resource-group idp-dev-rg \
  --name backstage-db --location centralindia \
  --admin-user backstage --admin-password CHANGE_ME --sku-name Standard_B1ms
# then deploy Backstage as another Argo CD Application, using this server's
# connection string in app-config.yaml
```

### Step 10 — Tear down

```bash
kubectl delete -f argocd/bootstrap/root-app.yaml
cd terraform/azure/envs/dev
terraform destroy
```

Or, since everything lives in one Resource Group: `az group delete --name idp-dev-rg --yes` deletes
every resource this platform created in a single command — one advantage of Azure's resource-group
model worth mentioning if asked to compare cleanup/teardown across clouds.

---

## What this costs, roughly (Central India region, dev-sized, running 24/7)

| Item | Approx. monthly cost |
|---|---|
| AKS control plane | Free (AKS doesn't charge for the control plane on the Free tier) |
| 3× Standard_D2s_v3 nodes | ~$210 |
| Standard Load Balancer | ~$20 |
| Managed disks (Prometheus + Grafana PVCs) | ~$5 |
| **Total** | **~$235/month** |

AKS's free control plane is a real cost advantage over EKS's flat $73/month — worth mentioning
explicitly if asked "which cloud is cheapest for this workload."
