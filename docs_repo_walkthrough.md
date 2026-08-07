# Complete Repo Walkthrough — Internal Developer Platform

This document goes through **every single file** in the repo, in the order Terraform → Argo CD →
monitoring → app → CI/CD, explaining what it does, why it's written that way, how it connects to
the rest of the platform, and what to say if an interviewer points at that exact file and asks
"walk me through this."

Read this alongside the actual files open side by side — this doc references real line content.

---

## PART 1 — `terraform/` (the foundation layer)

Terraform is the **only** thing that talks to AWS's control plane directly (creating VPCs, IAM
roles, the EKS cluster itself). Everything above it (Argo CD, Kubernetes workloads) talks to the
Kubernetes API instead. This split matters: Terraform owns "does the cluster exist," Argo CD owns
"what's running inside it."

### 1.1 `terraform/modules/vpc/main.tf` — the network

**What it creates, in dependency order:**

1. `aws_vpc.this` — a single VPC with CIDR `10.0.0.0/16` (65,536 IPs — generous headroom for
   future subnets without redesigning the network later).
2. `aws_internet_gateway.this` — the door between the VPC and the public internet.
3. `aws_subnet.public` (×3, one per AZ, using `for_each`) — these hold NAT gateways and any
   public-facing load balancers. `map_public_ip_on_launch = true` means anything launched here
   gets a public IP automatically.
4. `aws_subnet.private` (×3, one per AZ) — **this is where EKS worker nodes actually run.** No
   public IPs. This is a core security decision: your application pods are never directly
   reachable from the internet; all inbound traffic must go through a load balancer in the public
   subnet first.
5. `aws_eip.nat` + `aws_nat_gateway.this` (×3) — one Elastic IP + NAT Gateway **per AZ**. This lets
   private-subnet resources (worker nodes) reach the internet (e.g., to pull container images,
   call AWS APIs) without being reachable *from* the internet.
6. Route tables — the public route table sends `0.0.0.0/0` traffic to the Internet Gateway; each
   AZ's private route table sends `0.0.0.0/0` to *that AZ's own* NAT Gateway (not a shared one).

**Why `for_each` instead of `count`:** `for_each` keys resources by AZ name (e.g.,
`ap-south-1a`), so if you ever add a 4th AZ, Terraform only creates the *new* subnet — it doesn't
recalculate indices and accidentally try to destroy/recreate existing subnets, which `count`-based
lists are notorious for doing.

**The two special tag blocks** (`kubernetes.io/role/elb` and `kubernetes.io/cluster/<name>`) are
not decorative — the AWS Load Balancer Controller (or the legacy in-tree provider) scans subnets
for these exact tags to decide where to place ALBs/NLBs automatically. Forget these tags and
`kubectl apply` of an Ingress will hang forever with no useful error message — a very common
real-world debugging trap, worth mentioning if asked "what's a networking issue you've hit."

**The interview-defensible trade-off in this file:** one NAT Gateway per AZ costs roughly 3× a
single shared NAT Gateway (~$32/month each vs. one ~$32/month total), but removes the scenario
where one AZ's NAT Gateway failure takes down internet egress for workloads in a *different,
otherwise-healthy* AZ. State this trade-off explicitly if asked "how would you reduce this
architecture's cost" — the answer is "collapse to a single NAT Gateway for a dev/staging
environment, keep per-AZ NAT only in production."

### 1.2 `terraform/modules/eks/main.tf` — the cluster

**What it creates, in dependency order:**

1. `aws_iam_role.cluster` + policy attachment (`AmazonEKSClusterPolicy`) — the identity the EKS
   control plane itself assumes to manage AWS resources on your behalf (like creating ENIs).
2. `aws_iam_role.node` + three policy attachments — the identity every **worker node** assumes:
   - `AmazonEKSWorkerNodePolicy` — lets the node register with the cluster and function as a
     kubelet.
   - `AmazonEKS_CNI_Policy` — lets the VPC CNI plugin attach/detach ENIs and assign pod IPs.
   - `AmazonEC2ContainerRegistryReadOnly` — lets nodes pull images from ECR without embedding
     registry credentials anywhere.
3. `aws_eks_cluster.this` — the managed control plane. Note `endpoint_private_access = true` and
   `endpoint_public_access = true` together — the API server is reachable both from inside the VPC
   *and* from the internet (with IAM auth still required). This is explicitly called out as a
   portfolio-project trade-off: a real enterprise platform would set `endpoint_public_access =
   false` and require a VPN or Direct Connect, but that would make the demo unreachable for anyone
   without your company's VPN, so it's a deliberate, documented compromise — not an oversight.
4. `aws_eks_node_group.default` — the actual EC2 instances (via a managed node group, which
   handles the underlying Auto Scaling Group for you). `scaling_config` sets min 2 / desired 3 /
   max 6. `update_config.max_unavailable = 1` controls node-group upgrades: only one node is
   replaced at a time during a version bump, so you never lose more than 1/3 of a 3-node cluster's
   capacity mid-upgrade.

**Why a managed node group and not Fargate:** Fargate would remove node patching entirely (AWS
manages the underlying host), but Fargate can't run DaemonSets — and this platform *requires* a
DaemonSet (`node-exporter`, which Prometheus needs to get host-level CPU/memory/disk metrics).
Fargate pricing is also roughly double per-vCPU/GB compared to EC2 at steady utilization. This is
one of the highest-value trade-offs to be able to explain unprompted.

**Why a managed node group and not fully self-managed EC2 + Auto Scaling Group by hand:**
self-managed gives full control over AMI, bootstrap scripts, and lifecycle hooks, but you own
patching the AMI, handling node draining on termination, and wiring up the Auto Scaling Group's
lifecycle hooks yourself. A managed node group gives up some of that control in exchange for AWS
handling node draining and upgrade orchestration — the right trade for a platform team that wants
to spend its time on developer experience, not node lifecycle plumbing.

**Outputs** (`cluster_name`, `cluster_endpoint`, `cluster_ca`, `oidc_issuer`): the `oidc_issuer`
output specifically exists so a future addition — IAM Roles for Service Accounts (IRSA), which
lets individual Kubernetes pods assume specific IAM roles instead of inheriting the node's broad
IAM role — can be wired up without re-reading Terraform state by hand. It's not used elsewhere in
this repo yet; flagging that gap and explaining IRSA is itself a strong interview answer to "what
would you improve here."

### 1.3 `terraform/envs/dev/main.tf` — the root module you actually run

This is the only file where you type `terraform apply`. Three decisions live here specifically:

1. **Remote state in S3 with a DynamoDB lock table** (the `backend "s3" {}` block). Local state
   (the default) works fine solo, but the moment a second engineer — or CI — runs `terraform
   apply` concurrently, two processes can corrupt the same state file. The DynamoDB table
   implements a distributed lock: whoever grabs the lock first, the second `apply` blocks until
   the first finishes. This is the single most common "gotcha" question interviewers ask about
   Terraform at scale — know it cold.
2. **Separate root modules per environment, not Terraform workspaces.** Workspaces share the same
   backend configuration and the same variable defaults unless you're careful — it's very easy to
   accidentally run `terraform apply` against the `prod` workspace while your `.tfvars` file is
   still pointed at dev-sized instance types. A separate directory (`envs/dev`, and later
   `envs/prod`) with its own state *key* makes that mistake structurally harder to make, at the
   cost of some duplicated boilerplate between environment directories.
3. **`data "aws_availability_zones" "available"`** — rather than hardcoding `ap-south-1a`,
   `ap-south-1b`, `ap-south-1c`, this queries AWS for whichever AZs are actually available in the
   account/region at apply time, then takes the first 3. This makes the same code portable across
   regions and accounts without editing hardcoded AZ names.

The `configure_kubectl` output is a convenience — it prints the exact `aws eks update-kubeconfig`
command so you never have to remember the cluster name syntax.

---

## PART 2 — `argocd/` (the GitOps control layer)

**The single idea to say out loud in an interview:** after `argocd/bootstrap/root-app.yaml` is
applied once, by hand, **nobody runs `kubectl apply` against this cluster again.** Every future
change to what's running is a pull request against this Git repo. That is the actual definition of
GitOps — not "we use Kubernetes," but "Git is the single source of truth and a controller
continuously reconciles the cluster to match it."

### 2.1 `argocd/bootstrap/root-app.yaml` — the one manual step

This is an Argo CD `Application` resource whose `source.path` points at `argocd/apps/` — a
*directory*, not a single manifest. Argo CD watches that directory and treats **every YAML file
inside it as another Application to manage.** This is the "app of apps" pattern: one root
Application that bootstraps N child Applications, and from then on, adding a new service to the
platform is "add one YAML file to `argocd/apps/` and open a PR" — no cluster access required.

Two fields matter most:
- `syncPolicy.automated.prune: true` — if a file is deleted from `argocd/apps/`, the corresponding
  resources are deleted from the cluster automatically. Git deletions become cluster deletions.
- `syncPolicy.automated.selfHeal: true` — if someone manually edits a live resource with `kubectl
  edit`, Argo CD detects the drift from Git and reverts it. This is what actually enforces "Git is
  the source of truth" — without `selfHeal`, GitOps is just a suggestion.

### 2.2 `argocd/apps/monitoring.yaml` — Argo CD deploying a Helm chart from two sources

This Application uses Argo CD's **multi-source** feature: `sources` (plural) instead of `source`.
One entry pulls the `kube-prometheus-stack` Helm chart directly from the Prometheus community Helm
repo; the second entry (`ref: values`) points back at *this Git repo* just to grab
`monitoring/values.yaml`. The `$values/monitoring/values.yaml` reference in the first source stitches
them together — Argo CD renders the public chart using values that live in your own private repo.
This is the standard pattern for "use an upstream chart, but keep customization in Git" without
forking the chart itself.

### 2.3 `argocd/apps/sample-service.yaml` — the golden path

This Application points at `app/k8s/` — plain Kubernetes YAML, no Helm chart. This is intentional:
a real platform typically offers *both* patterns (raw manifests for simple stateless services,
Helm for anything with configuration complexity like Prometheus), and this repo demonstrates both
so you can speak to when you'd use which. Raw YAML is easier to read and diff in a PR; Helm is
better once you have more than a couple of environments needing different values for the same
manifest shape.

---

## PART 3 — `monitoring/values.yaml` — observability configuration

This file only exists because of the multi-source wiring in section 2.2. Three decisions worth
explaining:

1. **`retention: 10d` with a 10Gi PVC, no `remote_write`.** Prometheus's local time-series
   database is retention-limited and single-node — it is *not* meant for long-term storage or
   multi-cluster queries. In a real production platform you'd add `remote_write` to send metrics
   to Thanos, Mimir, or Cortex for indefinite retention and cross-cluster querying. This repo
   documents that as an explicit scope cut for cost reasons, not a mistake.
2. **`grafana.adminPassword` is a placeholder string, deliberately flagged as insecure.** In any
   real deployment this must come from a Kubernetes `Secret` (or better, be provisioned via
   External Secrets Operator pulling from AWS Secrets Manager) — never committed to Git in plain
   text, even in a values file. Pointing this out unprompted in an interview signals security
   awareness.
3. **`dashboardProviders`** pre-wires a folder so a dashboard JSON for the sample service could be
   auto-loaded on Grafana startup rather than manually imported through the UI — a small "day one
   usability" detail that separates a platform team's Grafana from a default install.

---

## PART 4 — `app/` (the golden-path microservice)

This is what a **product team** actually owns and touches — everything under `app/` is meant to be
copy-pasted as a template for a team's *next* service.

### 4.1 `app/src/main.py` — the service itself

Three endpoints, each with a specific platform-integration purpose:
- `/` — the actual "business logic" (a placeholder, since this is a demo).
- `/health` — what Kubernetes' `livenessProbe` and `readinessProbe` call. It returns real uptime
  data (not just a bare `200 OK`), which matters during manual debugging of a crash-looping
  pod — if uptime resets every few seconds in the response body, you're watching a live
  crash-loop, not guessing from Kubernetes events alone.
- `/metrics` — Prometheus's scrape target. The `Counter` object (`app_requests_total`) is the
  simplest possible custom application metric; it demonstrates the platform pattern "add a metric,
  the platform's observability stack finds it automatically" without needing platform-team
  involvement, because `ServiceMonitor` (section 4.3) already tells Prometheus where to look.

### 4.2 `app/Dockerfile` — the build

**Multi-stage build:** the `builder` stage installs Python dependencies into `/build/deps`; the
final stage copies *only* that directory in, never the pip cache, build tools, or source
`requirements.txt` install machinery. This keeps the final image smaller and reduces its attack
surface (fewer packages = fewer potential CVEs for Trivy to flag).

**Non-root user** (`addgroup`/`adduser`, then `USER app`): if an attacker achieves code execution
inside this container, they land as an unprivileged user, not root — meaningfully raising the bar
for a container breakout to escalate to the underlying node. This is one of the checks a security
reviewer (or Trivy's misconfiguration scanning) looks for immediately, and it's a common "what
security practices do you follow in your Dockerfiles" interview question.

### 4.3 `app/k8s/deployment.yaml` — three resources in one file

1. **`Deployment`** — `replicas: 2` with `podAntiAffinity` (`preferredDuringSchedulingIgnoredDuringExecution`)
   keyed on `kubernetes.io/hostname`. This tells the scheduler "prefer to place these two pods on
   different nodes." It's a *preferred*, not *required* affinity — if the cluster only has one
   healthy node available during an incident, Kubernetes will still schedule both pods there
   rather than leaving one pending forever. That's the correct default for a small cluster; a
   larger, stricter platform might use `requiredDuringScheduling` instead and accept the risk of a
   pod staying `Pending`.
2. **`Service`** — a plain `ClusterIP` (implicit default) exposing port 80 → container port 8080.
   Named port `http` matters: the `ServiceMonitor` below references it by name, not number.
3. **`ServiceMonitor`** (a Prometheus Operator CRD, not a native Kubernetes resource) — this is the
   single file a product team adds to get their service's metrics into Prometheus with zero
   platform-team involvement. Its `selector.matchLabels` finds the `Service` by the `app` label;
   its own `labels.release: monitoring` is what makes kube-prometheus-stack's Prometheus instance
   *notice* this ServiceMonitor in the first place (the chart's default `serviceMonitorSelector`
   only picks up ServiceMonitors with that exact label — a very common "why isn't my service
   showing up in Prometheus" debugging scenario worth being ready to explain).

**Placeholder to know:** `image: YOUR_REGISTRY/sample-service:latest` is never actually deployed
with the `latest` tag in practice — the CI pipeline (Part 5) overwrites this line with a specific
commit-SHA tag on every successful build. Using `:latest` in a real cluster is itself an anti-pattern
(no way to know what's actually running, no clean rollback target) — worth naming as a gap if
asked, even though CI fixes it in the real flow.

---

## PART 5 — `.github/workflows/ci-cd.yaml` — the pipeline

Walk this top to bottom; each stage maps directly to the "build → test → scan → deploy" phrasing
from the brief:

1. **Trigger** — `on: push: branches: [main], paths: [app/**]`. The pipeline only fires when
   something under `app/` changes — a Terraform-only or Argo-config-only commit doesn't rebuild
   the microservice. This scoping matters at real-company scale where a monorepo might have dozens
   of services; without path filtering, every commit anywhere would trigger every service's
   pipeline.
2. **`permissions: id-token: write`** — this is what enables **OIDC federation into AWS**. GitHub
   issues a short-lived, cryptographically signed OIDC token that AWS's IAM trusts (via a
   configured identity provider + trust policy scoped to this specific repo). The result: **no
   long-lived AWS access keys are ever stored as GitHub Secrets.** If this repo were ever forked or
   leaked, there's no static credential to rotate — the trust relationship is scoped to the exact
   repo/branch. This is one of the highest-signal security details you can mention unprompted.
3. **Test stage** — `pytest app/src/test_main.py`. Runs *before* the Docker build so a broken unit
   test fails fast, before spending time building and scanning an image that would just get
   thrown away anyway.
4. **Build stage** — a plain `docker build`, tagged with `${{ github.sha }}` — the full commit
   hash, not a version number or `latest`. This guarantees the tag is unique and traceable back to
   an exact commit, forever.
5. **Scan stage** — Trivy, configured with `severity: CRITICAL,HIGH` and `exit-code: 1`. If Trivy
   finds any fixable CRITICAL or HIGH vulnerability, the job fails here and the pipeline stops —
   the image is never pushed, so a vulnerable image can never even reach the registry, let alone
   the cluster. `ignore-unfixed: true` avoids failing builds over CVEs with no available patch yet,
   which would otherwise block every deploy indefinitely for issues you can't actually fix.
6. **Push stage** — `configure-aws-credentials@v4` exchanges the OIDC token for temporary AWS
   credentials scoped to the `github-actions-ecr-push` role, then logs into ECR and pushes the
   image, still tagged with the commit SHA.
7. **"Deploy" stage — which isn't actually a deploy.** The last step runs `sed` to rewrite the
   `image:` line inside `app/k8s/deployment.yaml` to point at the new commit-SHA-tagged image, then
   commits and pushes that change back to the repo. **CI's job ends here.** It never runs `kubectl
   apply`, never calls the Kubernetes API, and never needs cluster credentials of any kind. Argo
   CD — already watching this repo per Part 2 — picks up the change within its poll interval (or
   instantly via a webhook, if configured) and reconciles the cluster.

**Why this split matters, stated as a single interview-ready sentence:** *"CI is responsible for
producing a trustworthy artifact — tested, scanned, uniquely tagged. Argo CD is responsible for
making the cluster match Git. Splitting those two responsibilities means CI never needs
production credentials, and every single deploy has a Git commit and a one-command rollback
(`git revert`) instead of being an untracked, unrepeatable `kubectl` or `helm` command someone ran
from their laptop."*

---

## PART 5.5 — `backstage/` (the developer-facing front door)

Everything in Parts 1–5 is infrastructure a **platform team** understands deeply. Backstage is
what makes that infrastructure usable by a **product engineer who has never opened Terraform,
Argo CD, or `kubectl`.** This is the difference worth stating precisely in an interview: without a
portal layer, this repo is "well-built cloud infrastructure." With it, it's an actual **Internal
Developer Platform** — the term specifically implies a self-service front door, not just
consistent infrastructure underneath.

### 5.5.1 `app/catalog-info.yaml` — putting the existing service in the catalog

Three Backstage entity kinds in one file:
- **`Component: sample-service`** — the service itself. The `github.com/project-slug` annotation
  is what lets Backstage's GitHub Actions plugin render live CI run status directly on this
  component's page — a developer sees "last deploy: passed, 4 minutes ago" without leaving the
  portal to go find the right workflow run.
- **`System: internal-developer-platform`** — a grouping concept. As more services get scaffolded
  (Part 5.5.2), they all declare `system: internal-developer-platform`, so the catalog can render
  "everything that belongs to this platform" as one browsable page, not a flat list of unrelated
  services.
- **`Resource: eks-dev-cluster`** — represents infrastructure Terraform created (Part 1.3) as a
  first-class catalog entity, so `sample-service`'s `dependsOn` can point at it. This is what
  turns "our service depends on our cluster" from tribal knowledge into a queryable graph edge in
  the catalog UI.

**Why this file lives inside `app/`, not a central catalog registry repo:** co-location means the
catalog entry moves, renames, and deletes in lockstep with the code it describes. A central
registry repo listing every service's catalog file separately would drift the moment someone
deletes a service repo and forgets the corresponding registry entry — a very real failure mode at
companies with hundreds of services and a central "please register your service here" wiki page.

### 5.5.2 `backstage/templates/microservice-template/template.yaml` — the actual self-service part

This is a Backstage **Scaffolder** template — it renders as a form inside the Backstage UI. Walk
its `steps` in order, because this sequence *is* the golden path:

1. **`fetch:template`** — takes everything in `skeleton/` (parameterized copies of `app/`'s files)
   and renders the `${{ values.* }}` placeholders with whatever the developer typed into the form
   (`serviceName`, `description`, `owner`).
2. **`publish:github`** — creates a brand-new GitHub repository from the rendered skeleton.
3. **`catalog:register`** — registers the new repo's `catalog-info.yaml` in Backstage automatically,
   so the new service shows up in the catalog the instant it's created — no separate manual step.
4. **`argocd-app`** (placeholder in this reference repo) — in a real deployment, this step would
   call the GitHub API to open a pull request against *this* repo's `argocd/apps/` directory,
   adding `<serviceName>.yaml`. **Deliberately a PR, not a direct commit** — a platform engineer
   reviews and merges it before Argo CD starts managing the new service's resources. This is the
   one intentional human checkpoint in an otherwise fully automated flow, and it's worth defending
   explicitly: full zero-touch automation here would mean a typo'd scaffolder run could silently
   create cluster resources with no review at all.

**Why only 3 required form fields** (`serviceName`, `owner`, plus optional `description`): every
additional required field in a scaffolder form is friction that pushes a developer back toward "​I'll
just copy the old service folder by hand instead" — which defeats the entire point of having a
portal. The form asks for the minimum that genuinely can't be defaulted; anything else (resource
sizing, extra environment variables) becomes a follow-up PR against the generated repo instead of
a blocking form field.

### 5.5.3 `backstage/templates/microservice-template/skeleton/` — what actually gets stamped out

Compare these three files side-by-side with their `app/` counterparts (Part 4) — they're the same
pattern, parameterized:
- `skeleton/app/src/main.py` — identical `/`, `/health`, `/metrics` shape as `app/src/main.py`.
- `skeleton/app/k8s/deployment.yaml` — identical Deployment + Service + `ServiceMonitor` shape as
  `app/k8s/deployment.yaml`, including the same `release: monitoring` label the Prometheus
  Operator needs.
- `skeleton/catalog-info.yaml` — a minimal `Component` entity, `lifecycle: experimental` (not
  `production` like the hand-registered `sample-service`) — a small, deliberate signal that
  freshly scaffolded services start in a different lifecycle stage until a team promotes them.

The interview-ready way to describe this: *"Every service on this platform gets Prometheus
scraping, health probes, and pod anti-affinity for free, on day one, because the scaffolder
generates the same manifest shape every time — a developer would have to actively remove
monitoring to *not* have it, instead of remembering to add it."*

### 5.5.4 `backstage/app-config.platform.yaml` — wiring Backstage to the real platform

This is not a full Backstage installation — Backstage is a separate Node.js application you
scaffold with `npx @backstage/create-app`. This file is the platform-specific configuration you
merge into that app's `app-config.yaml`. Three blocks matter:
- **`catalog.locations`** — tells Backstage to scan `app/catalog-info.yaml` and the scaffolder
  template file in *this* repo, rather than maintaining a separate list of every entity by hand.
- **`kubernetes.clusterLocatorMethods`** — points Backstage's Kubernetes plugin at the **same
  live cluster** Terraform provisioned (Part 1.3). This is what lets a developer see real pod
  status for their service without opening `kubectl` or the AWS console — Backstage becomes a
  read-only window into cluster truth, not a second source of infrastructure state.
- **`techdocs`** — renders this repo's own Markdown (this document, the README) as each
  component's documentation page. Docs get reviewed in the same pull request as the code change
  that needs them, instead of drifting out of sync in a separate wiki.

---

## PART 6 — `diagrams/architecture.svg`

The diagram mirrors the flow described in Part 5's closing paragraph exactly: Developer → GitHub
Actions (build/test/scan/push) → ECR, then GitHub Actions → Git commit → Argo CD → EKS cluster
(apps namespace + monitoring namespace) → Grafana, viewed by an engineer. The dashed arrow from
"Engineer" to the monitoring box represents a read-only relationship — engineers view dashboards,
they don't get direct cluster write access; only Argo CD does.

The Backstage box sits to the side with two arrows: a solid one into the Git-repo flow (scaffolding
a *new* service triggers the exact same CI → Argo CD path an existing service uses — Backstage
doesn't bypass the pipeline, it just automates the first commit into it), and a dashed read-only
one back out to the cluster (catalog + live pod status). Backstage never gets direct cluster write
access, same rule as engineers viewing Grafana — Argo CD remains the only writer.

If asked to redraw this on a literal whiteboard, draw it in exactly this top-to-bottom order and
narrate each arrow as you draw it — that sequencing *is* the answer to "walk me through your
platform."

---

## PART 7 — How every file maps back to an interview question

| If asked... | Point to... |
|---|---|
| "How do you avoid storing cloud credentials in CI?" | `.github/workflows/ci-cd.yaml` — OIDC federation, `permissions: id-token: write` |
| "How do you handle concurrent Terraform runs?" | `terraform/envs/dev/main.tf` — S3 backend + DynamoDB lock |
| "How does a new service get onto your platform?" | `argocd/apps/sample-service.yaml` — add one file, open a PR |
| "How do you know your metrics pipeline actually works end to end?" | `app/k8s/deployment.yaml`'s `ServiceMonitor` + `monitoring/values.yaml`'s chart defaults |
| "What happens if someone manually changes something in the cluster?" | `argocd/bootstrap/root-app.yaml` — `selfHeal: true` |
| "How do you keep a bad image out of production?" | `.github/workflows/ci-cd.yaml` — Trivy scan gate, `exit-code: 1` |
| "How would you scale this to 50 services?" | `argocd/apps/` app-of-apps pattern scales linearly — one file per service, no cluster changes needed |
| "What's the biggest thing you'd change for real production?" | README's closing section — private-only EKS endpoint, Thanos for metrics, OPA policy gate, per-environment Terraform state |
| "How does a developer create a brand-new service?" | `backstage/templates/microservice-template/template.yaml` — fill in 3 fields, get a repo + CI + Argo CD PR, zero infra knowledge required |
| "How do you keep your software catalog from going stale?" | `app/catalog-info.yaml` co-located inside the service repo — deleting the repo removes the catalog entry, nothing to forget |
| "Why isn't the scaffolder fully automated end-to-end?" | The `argocd-app` step opens a PR, not a direct commit — one deliberate human review gate before Argo CD manages new resources |

---

*Study order recommendation: read this document once fully, then open the actual repo files in a
second window and re-read each part while looking at the real file. The goal is to reach a point
where you can explain any single file from memory, unprompted, in under 60 seconds.*
