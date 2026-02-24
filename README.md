# 🚀 Golden Path — ECS Fargate Platform

A production-grade **"Golden Path"** for deploying microservices on AWS using **ECS Fargate**.  
Covers networking, compute, IAM (no static keys), secret injection, CI/CD, auto scaling, and observability — all managed through Terraform.

---

## Table of Contents

- [Architecture](#architecture)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
  - [Step 0 — Bootstrap Remote State](#step-0--bootstrap-remote-state)
  - [Step 1 — Configure Variables](#step-1--configure-variables)
  - [Step 2 — Deploy Infrastructure](#step-2--deploy-infrastructure)
  - [Step 3 — Verify](#step-3--verify)
- [Running Locally with Docker](#running-locally-with-docker)
- [CI/CD Pipeline](#cicd-pipeline)
- [Key Design Decisions](#key-design-decisions)
- [Cost Breakdown](#cost-breakdown)
- [Day-2 Operations](#day-2-operations)
- [Destroying Resources](#destroying-resources)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              AWS Region (us-east-1)                                 │
│                                                                                     │
│  ┌──────────────────────────────── VPC (10.0.0.0/16) ────────────────────────────┐ │
│  │                                                                                │ │
│  │   ╔══════════════════════════ PUBLIC SUBNETS ══════════════════════════════╗  │ │
│  │   ║  AZ-1a  10.0.101.0/24                 AZ-1b  10.0.102.0/24           ║  │ │
│  │   ║                                                                        ║  │ │
│  │   ║   ┌────────────────────────────────────────────────────────────────┐   ║  │ │
│  │   ║   │            Application Load Balancer (ALB)                     │   ║  │ │
│  │   ║   │         Listener: HTTP :80  →  Target Group (IP type)          │   ║  │ │
│  │   ║   └──────────────────────┬─────────────────────────────────────────┘   ║  │ │
│  │   ║                          │                                              ║  │ │
│  │   ║   ┌──────────────────────┘                                              ║  │ │
│  │   ║   │   NAT Gateway ──► Internet Gateway ──► Internet                    ║  │ │
│  │   ║   │   (AZ-1a only — single NAT for dev cost savings)                   ║  │ │
│  │   ╚═══╪════════════════════════════════════════════════════════════════════╝  │ │
│  │       │                                                                        │ │
│  │   ╔═══╪══════════════════ PRIVATE SUBNETS ══════════════════════════════════╗ │ │
│  │   ║   │  AZ-1a  10.0.1.0/24                  AZ-1b  10.0.2.0/24           ║ │ │
│  │   ║   │                                                                     ║ │ │
│  │   ║   ▼  ECS Fargate Cluster                                                ║ │ │
│  │   ║   ┌──────────────────────────────────────────────────────────────────┐  ║ │ │
│  │   ║   │                                                                  │  ║ │ │
│  │   ║   │   ┌─────────────────────┐    ┌─────────────────────┐            │  ║ │ │
│  │   ║   │   │   Task (SPOT) ★     │    │  Task (On-Demand)   │  ···       │  ║ │ │
│  │   ║   │   │  ┌───────────────┐  │    │  ┌───────────────┐  │            │  ║ │ │
│  │   ║   │   │  │ nginx:alpine  │  │    │  │ nginx:alpine  │  │            │  ║ │ │
│  │   ║   │   │  │ CPU:  0.25    │  │    │  │ CPU:  0.25    │  │            │  ║ │ │
│  │   ║   │   │  │ Mem:  512 MB  │  │    │  │ Mem:  512 MB  │  │            │  ║ │ │
│  │   ║   │   │  │ Port: 80      │  │    │  │ Port: 80      │  │            │  ║ │ │
│  │   ║   │   │  └───────────────┘  │    │  └───────────────┘  │            │  ║ │ │
│  │   ║   │   │  env: DB_PASSWORD ◄─┼────┼──── Secrets Manager │            │  ║ │ │
│  │   ║   │   │  role: Task Role ───┼────┼──►  S3 (no keys)    │            │  ║ │ │
│  │   ║   │   └─────────────────────┘    └─────────────────────┘            │  ║ │ │
│  │   ║   │                                                                  │  ║ │ │
│  │   ║   │   Auto Scaling: min=1  desired=2  max=4  (CPU > 60% → scale out) │  ║ │ │
│  │   ║   └──────────────────────────────────────────────────────────────────┘  ║ │ │
│  │   ║                                                                          ║ │ │
│  │   ║   VPC Endpoints (private, no NAT needed for AWS API calls)              ║ │ │
│  │   ║   ┌────────────┐ ┌────────────┐ ┌──────────────┐ ┌──────────────────┐  ║ │ │
│  │   ║   │  ECR API   │ │  ECR DKR   │ │  S3 Gateway  │ │  CloudWatch Logs │  ║ │ │
│  │   ║   └────────────┘ └────────────┘ └──────────────┘ └──────────────────┘  ║ │ │
│  │   ║   ┌──────────────────┐                                                  ║ │ │
│  │   ║   │ Secrets Manager  │                                                  ║ │ │
│  │   ║   └──────────────────┘                                                  ║ │ │
│  │   ╚══════════════════════════════════════════════════════════════════════════╝ │ │
│  └────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                     │
│   ┌─────────────────┐   ┌──────────────────┐   ┌─────────────────────────────────┐ │
│   │   S3 Buckets    │   │    DynamoDB       │   │       Secrets Manager           │ │
│   │                 │   │                  │   │                                 │ │
│   │  ► TF state     │   │  ► TF state lock │   │  ► golden-path/dev/db-password  │ │
│   │  ► App data     │   │    (always free) │   │    injected as DB_PASSWORD env  │ │
│   │    (Task Role   │   │                  │   │    var at ECS task startup       │ │
│   │     access)     │   │                  │   │                                 │ │
│   └─────────────────┘   └──────────────────┘   └─────────────────────────────────┘ │
│                                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────────────┐   │
│   │  CloudWatch — 4 Golden Signals Dashboard                                    │   │
│   │                                                                              │   │
│   │  🕐 Latency    ALB TargetResponseTime  p50 / p95 / p99 (SLO: < 1s)        │   │
│   │  📈 Traffic    ALB RequestCount per minute + active connections             │   │
│   │  🚨 Errors     HTTP 5xx / 4xx counts + unhealthy host count                │   │
│   │  📊 Saturation ECS CPU % + Memory % with scale-out threshold annotations   │   │
│   └─────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────┘

Internet User
     │
     ▼  HTTP :80
┌──────────┐        ┌─────────┐        ┌───────────────┐        ┌──────────────┐
│  Browser │──────► │   ALB   │──────► │  ECS Service  │──────► │  S3 / AWS    │
│          │        │ (public │        │  (private     │        │  APIs via    │
│          │        │ subnet) │        │   subnet)     │        │  Task Role   │
└──────────┘        └─────────┘        └───────────────┘        └──────────────┘
                                               │
                                               ▼ at startup
                                       ┌───────────────┐
                                       │ Secrets Mgr   │
                                       │ DB_PASSWORD   │
                                       │ (via ECS exec │
                                       │  role, auto)  │
                                       └───────────────┘

CI/CD Flow (GitHub Actions)
     │
     ├── PR opened
     │     └── terraform plan → post diff as PR comment
     │
     └── Merge to main
           ├── 1. terraform plan
           ├── 2. docker build + smoke test + Trivy CVE scan
           ├── 3. terraform apply
           ├── 4. docker build + push → ECR (tagged with git SHA)
           └── 5. ecs update-service → wait for stability
```

---

## Project Structure

```
golden-path/
│
├── bootstrap/                        # Run ONCE before everything else
│   └── main.tf                       # Creates S3 + DynamoDB for TF remote state
│
├── modules/
│   ├── networking/
│   │   └── main.tf                   # VPC, public/private subnets, NAT GW,
│   │                                 # IGW, route tables, 5 VPC endpoints
│   ├── ecs/
│   │   └── main.tf                   # ECS cluster, task definition, Fargate service,
│   │                                 # ALB, target group, Application Auto Scaling
│   ├── iam/
│   │   └── main.tf                   # Task Execution Role (ECS agent bootstrap)
│   │                                 # Task Role (app S3 access — no static keys)
│   ├── secrets/
│   │   └── main.tf                   # Secrets Manager secret + initial version
│   └── observability/
│       └── main.tf                   # CloudWatch dashboard (4 Golden Signals)
│                                     # + 5 CloudWatch alarms
│
├── .github/
│   └── workflows/
│       └── deploy.yml                # Full CI/CD: plan → build → apply → push → deploy
│
├── Dockerfile                        # Multi-stage: alpine builder → nginx:alpine runtime
├── entrypoint.sh                     # Runtime env injection + graceful shutdown
├── docker-compose.yml                # Local dev environment (mirrors ECS)
├── .env.example                      # Template for local secrets
├── .dockerignore                     # Prevents .tfstate / .env leaking into image
│
├── backend.tf                        # Remote state config (update after bootstrap)
├── provider.tf                       # AWS provider + Terraform version constraints
├── variables.tf                      # All input variables with safe defaults
├── main.tf                           # Root orchestrator — wires all modules
├── outputs.tf                        # ALB URL, cluster/service names, dashboard URL
└── terraform.tfvars.example          # Copy to terraform.tfvars to customise
```

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Terraform | >= 1.6.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | >= 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Docker | >= 24.x | https://docs.docker.com/get-docker/ |
| Git | Any | https://git-scm.com/downloads |

**AWS credentials** — Configure before running any Terraform commands:

```bash
# Option A: AWS CLI profile
aws configure

# Option B: Environment variables
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1

# Verify access
aws sts get-caller-identity
```

---

## Quick Start

### Step 0 — Bootstrap Remote State

> **Run this once only.** This creates the S3 bucket and DynamoDB table that
> Terraform uses to store and lock its own state file.

```bash
cd bootstrap/
terraform init
terraform apply
```

When it completes, copy the `backend_config_snippet` output value. It will look like this:

```hcl
terraform {
  backend "s3" {
    bucket         = "golden-path-tfstate-123456789012"
    key            = "golden-path/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "golden-path-tfstate-lock"
    encrypt        = true
  }
}
```

Open `backend.tf` in the project root and replace its contents with that snippet.

```bash
cd ..   # return to project root
```

---

### Step 1 — Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and review the defaults. The most common values to change:

```hcl
aws_region   = "us-east-1"    # change to your preferred region
project_name = "golden-path"  # used as a prefix for all resource names
environment  = "dev"

# App settings
app_image  = "nginx:1.27-alpine"   # public image — no auth needed
app_cpu    = 256                   # 0.25 vCPU (minimum Fargate unit)
app_memory = 512                   # 512 MiB   (minimum paired with 256 CPU)

# Secrets Manager
db_password_secret_name = "golden-path/dev/db-password"
```

> **Note:** Leave `db_password_secret_name` as-is for dev. After the first `apply`,  
> update the actual secret value using the AWS CLI (see [Day-2 Operations](#day-2-operations)).

---

### Step 2 — Deploy Infrastructure

**Initialise Terraform** (connects to the remote S3 backend):

```bash
terraform init
```

Expected output:
```
Initializing the backend...
Successfully configured the backend "s3"!

Initializing modules...
- ecs in modules/ecs
- iam in modules/iam
- networking in modules/networking
- observability in modules/observability
- secrets in modules/secrets

Terraform has been successfully initialized!
```

---

**Preview changes** before applying:

```bash
terraform plan
```

Review the output. You should see resources being created across all five modules. No resources are created at this stage — it is read-only.

---

**Apply the infrastructure:**

```bash
terraform apply
```

Terraform will print the plan one more time and ask for confirmation:

```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes
```

Type `yes` and press Enter. The full apply takes approximately **5–10 minutes**, with the ALB and ECS service taking the longest to become healthy.

---

### Step 3 — Verify

Once `apply` completes, check the outputs:

```bash
terraform output
```

```
alb_dns_name             = "golden-path-dev-alb-1234567890.us-east-1.elb.amazonaws.com"
alb_url                  = "http://golden-path-dev-alb-1234567890.us-east-1.elb.amazonaws.com"
cloudwatch_dashboard_url = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?..."
ecs_cluster_name         = "golden-path-dev-cluster"
ecs_service_name         = "golden-path-dev-hello-world-svc"
```

**Test the app:**

```bash
curl $(terraform output -raw alb_url)
# → nginx HTML response (Hello World page)
```

**Test the health endpoint:**

```bash
curl $(terraform output -raw alb_url)/health
# → {"status":"healthy","service":"hello-world"}
```

**Open the CloudWatch Dashboard:**

```bash
# Copy this URL into your browser
terraform output cloudwatch_dashboard_url
```

**Check ECS service status:**

```bash
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name) \
  --query "services[0].{Status:status,Running:runningCount,Desired:desiredCount,Pending:pendingCount}"
```

Expected output:

```json
{
  "Status": "ACTIVE",
  "Running": 2,
  "Desired": 2,
  "Pending": 0
}
```

---

## Running Locally with Docker

Test the app locally before deploying. This mirrors the ECS Fargate environment:

```bash
# Copy the env example
cp .env.example .env

# Edit .env with your local values (DB_PASSWORD etc.)
# Then build and run:
docker compose up --build

# Test in another terminal
curl http://localhost:8080/
curl http://localhost:8080/health

# Stop when done
docker compose down
```

**Build the image manually** (with the same args used in CI):

```bash
docker build \
  --build-arg APP_VERSION=1.0.0 \
  --build-arg GIT_COMMIT=$(git rev-parse --short HEAD) \
  --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  -t golden-path-hello-world:local \
  .
```

---

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/deploy.yml`) runs automatically on every push to `main`:

```
Push to main
    │
    ├── Job 1: terraform-plan
    │     ├── terraform fmt -check
    │     ├── terraform validate
    │     └── terraform plan  ──► posts diff as PR comment
    │
    ├── Job 2: docker-build  (runs in parallel with Job 1)
    │     ├── docker build (no push)
    │     ├── smoke test: curl /  and  curl /health
    │     └── trivy scan: fail on CRITICAL CVEs
    │
    ├── Job 3: terraform-apply  (after Jobs 1 + 2 pass)
    │     └── terraform apply -auto-approve
    │
    ├── Job 4: ecr-push  (after Job 3)
    │     ├── docker build + tag with git SHA
    │     ├── push to ECR  (tagged :sha + :latest)
    │     └── attach SBOM + provenance attestations
    │
    └── Job 5: ecs-deploy  (after Job 4)
          ├── fetch current task definition
          ├── inject new image URI (SHA tag)
          ├── register new task definition revision
          └── update ECS service → wait for stability
```

**Required GitHub Secrets** — set these under `Settings → Secrets → Actions`:

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | ARN of the OIDC-federated IAM role |
| `AWS_REGION` | `us-east-1` |
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `ECR_REPOSITORY` | ECR repository name (e.g. `golden-path-hello-world`) |
| `TF_STATE_BUCKET` | S3 bucket name from bootstrap output |
| `TF_STATE_DYNAMODB` | DynamoDB table name from bootstrap output |
| `ECS_CLUSTER_NAME` | From `terraform output ecs_cluster_name` |
| `ECS_SERVICE_NAME` | From `terraform output ecs_service_name` |
| `ECS_TASK_FAMILY` | Task definition family name |
| `ECS_CONTAINER_NAME` | Container name in task def (e.g. `hello-world`) |

> GitHub Actions authenticates to AWS via **OIDC federation** — no `AWS_ACCESS_KEY_ID`  
> or `AWS_SECRET_ACCESS_KEY` is stored anywhere in GitHub.

---

## Key Design Decisions

### ECS Fargate over EKS

| | ECS Fargate | EKS |
|---|---|---|
| Control plane cost | **FREE** | ~$73/month (always billed) |
| Operational overhead | Low — AWS-managed | High — K8s expertise + add-ons |
| Secret injection | Native (task definition `secrets` block) | External Secrets Operator required |
| IAM credential delivery | Task Role via metadata endpoint | IRSA via OIDC + service account |
| Spot support | FARGATE_SPOT (up to 70% cheaper) | Spot node groups (more complex) |
| Best for | AWS-only workloads | Multi-cloud / hybrid |

### Spot + On-Demand Fallback

The ECS service uses a mixed capacity provider strategy. ECS automatically falls back to On-Demand when Spot capacity is unavailable — no manual intervention needed.

```
FARGATE_SPOT  weight=4  →  80% of tasks   (cheapest, interruptible)
FARGATE       weight=1  →  20% of tasks   (guaranteed capacity)
              base=1    →  always keep ≥1 On-Demand task running
```

### ECS Task Role = IRSA Equivalent

The application container accesses S3 with zero configuration. The AWS SDK automatically picks up rotating short-lived credentials from the ECS task metadata endpoint (`169.254.170.2`) — identical in security model to Kubernetes IRSA, with no static access keys involved.

### Secret Injection

ECS injects the `DB_PASSWORD` environment variable at task startup by reading from Secrets Manager using the Task Execution Role. The application reads `process.env.DB_PASSWORD` — no AWS SDK calls, no secret management code in the app.

---

## Cost Breakdown

| Resource | Config | Est. Cost |
|---|---|---|
| ECS Cluster | Control plane | **FREE** |
| Fargate Spot | 0.25 vCPU / 512 MB | ~$1–3 / month |
| Fargate On-Demand | 0.25 vCPU / 512 MB (base=1) | ~$5–7 / month |
| Application Load Balancer | 1 ALB, low traffic | ~$6 / month |
| NAT Gateway | 1 NAT, ~1 GB/day | ~$33 / month |
| S3 (state + app data) | < 1 GB | **FREE** (12 mo) |
| DynamoDB (TF locks) | On-demand | **FREE** (always) |
| Secrets Manager | 1 secret | $0.40 / month |
| CloudWatch | Basic metrics + dashboard | **FREE** |
| VPC / Subnets / IGW | — | **FREE** |

> **Biggest cost: NAT Gateway (~$33/month).** To eliminate it, set `enable_nat_gateway = false`
> in `modules/networking/main.tf`. The five VPC Interface Endpoints handle all AWS API
> traffic (ECR, S3, CloudWatch, Secrets Manager) without going through NAT.

---

## Day-2 Operations

**Rotate the DB password:**

```bash
aws secretsmanager put-secret-value \
  --secret-id "golden-path/dev/db-password" \
  --secret-string "your-new-password-here"

# Restart ECS tasks to pick up the new value
aws ecs update-service \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --service $(terraform output -raw ecs_service_name) \
  --force-new-deployment
```

**Check running tasks and their capacity type (Spot vs On-Demand):**

```bash
aws ecs list-tasks \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --service-name $(terraform output -raw ecs_service_name)
```

**Manually scale the service:**

```bash
aws ecs update-service \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --service $(terraform output -raw ecs_service_name) \
  --desired-count 4
```

**View container logs in CloudWatch:**

```bash
aws logs tail /ecs/golden-path-dev/hello-world --follow
```

**SSH into a running task (ECS Exec):**

```bash
aws ecs execute-command \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --task <TASK_ID> \
  --container hello-world \
  --interactive \
  --command "/bin/sh"
```

---

## Destroying Resources

> ⚠️ This is irreversible. All ECS tasks, the ALB, VPC, and secrets will be deleted.

```bash
# Destroy all main infrastructure
terraform destroy

# Optionally destroy the bootstrap resources (removes the TF state bucket too)
# WARNING: do this only if you are permanently done with this project
cd bootstrap/
terraform destroy
```

The S3 state bucket has `prevent_destroy = true` as a safety guard. To override it,
remove that lifecycle block from `bootstrap/main.tf` before running destroy.
