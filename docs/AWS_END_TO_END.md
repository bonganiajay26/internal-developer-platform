# AWS — End-to-end implementation guide

Everything you need to go from zero to a fully running platform on AWS: prerequisites, exact
services used, and every command in order. No step skipped.

---

## 1. Services used (complete list)

| Service | Role in this platform |
|---|---|
| VPC, Subnets, Internet Gateway, NAT Gateway, Route Tables | Networking layer (`terraform/aws/modules/vpc`) |
| EKS (Elastic Kubernetes Service) | Managed Kubernetes control plane (`terraform/aws/modules/eks`) |
| EC2 (via EKS managed node group) | Worker nodes that actually run pods |
| IAM (roles + policies, OIDC provider) | Cluster/node identity, and GitHub Actions federation (no static keys) |
| ECR (Elastic Container Registry) | Stores the microservice's Docker images |
| S3 | Terraform remote state, TechDocs storage (if hosting Backstage here) |
| DynamoDB | Terraform state lock table |
| Secrets Manager | Grafana admin password, Backstage's GitHub token, DB credentials |
| RDS for PostgreSQL | Backstage's catalog/scaffolder database (if hosting Backstage on AWS) |
| Route 53 + ACM | DNS and TLS certificate for the Backstage portal URL (optional, for a real domain) |
| CloudWatch (optional) | Native AWS monitoring, alongside the self-hosted Prometheus/Grafana stack |

## 2. Prerequisites

- An AWS account with billing alerts enabled (AWS Budgets)
- IAM user/role with permission to create VPCs, EKS clusters, IAM roles, S3 buckets, DynamoDB tables
- Installed locally: `aws` CLI v2, `terraform` >= 1.7, `kubectl`, `helm`, `docker`
- A GitHub repository this code is pushed to (for the CI/CD steps)

## 3. End-to-end steps

### Step 1 — Bootstrap Terraform remote state (one-time, manual, before any `terraform init`)

```bash
aws s3api create-bucket --bucket YOUR_TF_STATE_BUCKET --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
aws s3api put-bucket-versioning --bucket YOUR_TF_STATE_BUCKET \
  --versioning-configuration Status=Enabled

aws dynamodb create-table --table-name YOUR_TF_LOCK_TABLE \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Edit `terraform/aws/envs/dev/main.tf`'s `backend "s3" {}` block with these exact names.

### Step 2 — Provision the network and cluster

```bash
cd terraform/aws/envs/dev
terraform init
terraform plan     # review before applying — this creates real billable resources
terraform apply
```

This creates: 1 VPC, 3 public + 3 private subnets, 3 NAT Gateways, 1 EKS cluster, 1 managed node
group (2–6 nodes, autoscaling). Takes roughly 12–15 minutes — most of that is EKS control plane
provisioning.

### Step 3 — Point kubectl at the new cluster

```bash
aws eks update-kubeconfig --region ap-south-1 --name idp-dev-eks
kubectl get nodes    # should show 3 nodes in Ready state
```

### Step 4 — Create the ECR repository for the microservice

```bash
aws ecr create-repository --repository-name sample-service --region ap-south-1
```

### Step 5 — Set up GitHub OIDC federation into AWS (no static keys)

```bash
# 1. Create the OIDC identity provider (one-time per AWS account)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# 2. Create the IAM role GitHub Actions will assume — trust policy scoped to
#    YOUR exact repo, so no other repo can assume this role even if they knew its ARN
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:YOUR_USERNAME/internal-developer-platform:*" }
    }
  }]
}
EOF

aws iam create-role --role-name github-actions-ecr-push --assume-role-policy-document file://trust-policy.json
aws iam attach-role-policy --role-name github-actions-ecr-push \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```

Replace `ACCOUNT_ID` in `.github/workflows/ci-cd-aws.yaml`'s `role-to-assume` line with your real
account ID.

### Step 6 — Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/bootstrap/root-app.yaml
kubectl get applications -n argocd   # wait until monitoring + sample-service show "Synced"
```

### Step 7 — Push code and let the pipeline run

```bash
git add .
git commit -m "Initial platform deploy"
git push
```

GitHub Actions runs `ci-cd-aws.yaml` → tests → builds → Trivy scans → pushes to ECR → commits the
new image tag → Argo CD syncs the cluster within its poll interval.

### Step 8 — Verify

```bash
kubectl get pods -n apps         # sample-service, 2 replicas Running
kubectl get pods -n monitoring   # prometheus, grafana, alertmanager Running
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# open http://localhost:3000 — default user "admin", password from monitoring/values.yaml
```

### Step 9 (optional) — Host Backstage on this same cluster

```bash
aws rds create-db-instance --db-instance-identifier backstage-db \
  --db-instance-class db.t3.micro --engine postgres \
  --master-username backstage --master-user-password CHANGE_ME \
  --allocated-storage 20
# then deploy Backstage as another Argo CD Application pointing at your
# Backstage Helm chart or manifests, using this RDS endpoint in app-config.yaml
```

### Step 10 — Tear down (avoid ongoing charges)

```bash
kubectl delete -f argocd/bootstrap/root-app.yaml
cd terraform/aws/envs/dev
terraform destroy
```

---

## What this costs, roughly (ap-south-1, dev-sized, running 24/7)

| Item | Approx. monthly cost |
|---|---|
| EKS control plane | $73 (flat fee) |
| 3× t3.medium nodes | ~$90 |
| 3× NAT Gateway | ~$100 (see cost-optimization doc — collapse to 1 for dev) |
| EBS volumes (Prometheus + Grafana PVCs) | ~$3 |
| **Total (before collapsing NAT)** | **~$266/month** |
| **Total (1 shared NAT instead of 3)** | **~$200/month** |

Shut the cluster down (`terraform destroy`) between study sessions if this is a portfolio project,
not a running service — there's no reason to pay for idle infrastructure between interviews.
