# 🚀 Golden Path — ECS Fargate Platform

A complete "Golden Path" for deploying microservices to AWS using ECS Fargate.
Covers all requirements: networking, compute, security, secrets, CI/CD, auto scaling, and observability.

---

## Architecture Overview

```
                          ┌──────────────────────────────────────────────────────────────┐
                          │                        AWS Region (us-east-1)                │
                          │                                                              │
  Internet ──── HTTPS ───►│  ┌──────────────── VPC (10.0.0.0/16) ──────────────────┐   │
                          │  │                                                       │   │
                          │  │  ┌─── Public Subnets ──────────────────────────────┐ │   │
                          │  │  │  AZ-1 (10.0.101.0/24)  AZ-2 (10.0.102.0/24)   │ │   │
                          │  │  │  ┌────────────────────────────────────────────┐ │ │   │
                          │  │  │  │      Application Load Balancer (ALB)       │ │ │   │
                          │  │  │  │         HTTP :80 → Target Group            │ │ │   │
                          │  │  │  └─────────────────┬──────────────────────────┘ │ │   │
                          │  │  │                    │ NAT Gateway (AZ-1)         │ │   │
                          │  │  └────────────────────┼────────────────────────────┘ │   │
                          │  │                       │                               │   │
                          │  │  ┌─── Private Subnets ┼─────────────────────────────┐│   │
                          │  │  │  AZ-1 (10.0.1.0/24)│ AZ-2 (10.0.2.0/24)        ││   │
                          │  │  │  ┌─────────────────▼──────────────────────────┐ ││   │
                          │  │  │  │         ECS Fargate Cluster                │ ││   │
                          │  │  │  │  ┌───────────────┐  ┌───────────────┐      │ ││   │
                          │  │  │  │  │  Task (Spot)  │  │  Task (OD)   │      │ ││   │
                          │  │  │  │  │  nginx:alpine │  │  nginx:alpine│      │ ││   │
                          │  │  │  │  │  CPU: 0.25    │  │  CPU: 0.25   │      │ ││   │
                          │  │  │  │  │  Mem: 512 MB  │  │  Mem: 512 MB │      │ ││   │
                          │  │  │  │  └───────────────┘  └───────────────┘      │ ││   │
                          │  │  │  │         ↕ Auto Scaling (CPU>60%)           │ ││   │
                          │  │  │  └────────────────────────────────────────────┘ ││   │
                          │  │  └──────────────────────────────────────────────────┘│   │
                          │  │                                                       │   │
                          │  │  VPC Endpoints: ECR API/DKR, S3, CloudWatch, Secrets │   │
                          │  └───────────────────────────────────────────────────────┘  │
                          │                                                              │
                          │  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐ │
                          │  │  S3 Bucket  │  │   DynamoDB   │  │  Secrets Manager   │ │
                          │  │  (TF State) │  │  (TF Locks)  │  │  DB_PASSWORD       │ │
                          │  │  (App Data) │  │              │  │  → injected as ENV │ │
                          │  └─────────────┘  └──────────────┘  └────────────────────┘ │
                          │                                                              │
                          │  ┌─────────────────────────────────────────────────────┐    │
                          │  │  CloudWatch — 4 Golden Signals Dashboard            │    │
                          │  │  Latency (p95) | Traffic (RPS) | Errors | Saturation│   │
                          │  └─────────────────────────────────────────────────────┘    │
                          └──────────────────────────────────────────────────────────────┘

  GitHub Actions:
  push to main → terraform plan → terraform apply → ecs update-service → ecs wait stable
```

---

## Project Structure

```
golden-path/
├── bootstrap/              # Step 0: Creates S3 + DynamoDB for Terraform state
│   └── main.tf
│
├── modules/
│   ├── networking/         # VPC, subnets, NAT GW, IGW, VPC endpoints
│   ├── ecs/                # Cluster, Task Def, Service, ALB, Auto Scaling
│   ├── iam/                # Task Execution Role + Task Role (ECS equiv. of IRSA)
│   ├── secrets/            # Secrets Manager secret + version
│   └── observability/      # CloudWatch Dashboard + Alarms (4 Golden Signals)
│
├── .github/workflows/
│   └── deploy.yml          # CI/CD: Plan → Apply → ECS Deploy
│
├── backend.tf              # Remote state config (update after bootstrap)
├── provider.tf             # AWS provider + Terraform version
├── variables.tf            # All input variables with defaults
├── main.tf                 # Root module wiring everything together
├── outputs.tf              # Key outputs (ALB URL, cluster name, etc.)
└── terraform.tfvars.example
```

---

## Quick Start

### Prerequisites

- AWS CLI configured (`aws configure` or environment variables)
- Terraform >= 1.6.0
- An AWS account (free tier eligible)

### Step 1 — Bootstrap Remote State

```bash
cd bootstrap/
terraform init
terraform apply

# Copy the "backend_config_snippet" output into ../backend.tf
```

### Step 2 — Deploy Infrastructure

```bash
cd ..  # back to project root

# Update backend.tf with the S3 bucket name from Step 1 output
# Then copy the example vars:
cp terraform.tfvars.example terraform.tfvars

# Init with remote backend
terraform init

# Preview changes
terraform plan

# Deploy everything
terraform apply
```

### Step 3 — Verify

```bash
# Get the ALB URL
terraform output alb_url

# Open in browser — you should see the nginx welcome page
curl $(terraform output -raw alb_url)

# View the CloudWatch Dashboard
terraform output cloudwatch_dashboard_url
```

---

## Design Decisions

### Why ECS Fargate over EKS?

| Concern | ECS Fargate | EKS |
|---|---|---|
| **Cluster cost** | FREE | ~$0.10/hr ($73/mo) mandatory |
| **Complexity** | Low — AWS-native | High — K8s expertise needed |
| **Multi-cloud** | AWS-only | Multi-cloud possible |
| **Operational overhead** | Near-zero | Significant (upgrades, add-ons) |
| **Free tier fit** | ✅ Yes | ❌ No (EKS control plane always billed) |

For a purely AWS workload, ECS Fargate gives you the same core capabilities (auto scaling, load balancing, service discovery, secret injection, IAM roles) without the EKS control plane cost or operational complexity.

### Spot + On-Demand Fallback

The ECS service uses a **mixed capacity provider strategy**:

```hcl
# 80% FARGATE_SPOT (up to 70% cheaper)
capacity_provider_strategy {
  capacity_provider = "FARGATE_SPOT"
  weight            = 4
  base              = 0
}

# 20% FARGATE On-Demand (guaranteed capacity, always-on baseline)
capacity_provider_strategy {
  capacity_provider = "FARGATE"
  weight            = 1
  base              = 1  # ← Always keep at least 1 On-Demand task
}
```

ECS automatically handles Spot interruption by replacing terminated tasks. The `base=1` on FARGATE ensures at least one On-Demand task is always running for reliability even during Spot shortages.

**Kubernetes equivalent:** Node groups with mixed instance policy (Spot + OD) + Cluster Autoscaler.

### ECS Task Role = IRSA Equivalent 

| Kubernetes IRSA | ECS Task Role |
|---|---|
| OIDC provider in IAM | IAM Trust Policy for `ecs-tasks.amazonaws.com` |
| Service Account annotation | `taskRoleArn` in Task Definition |
| Pod gets JWT from K8s API | Task gets temp creds from ECS metadata endpoint |
| SDK auto-discovers creds | SDK auto-discovers creds (same credential chain) |
| No static access keys | No static access keys |

The app running inside the ECS container calls S3 using standard AWS SDK with **zero configuration** — credentials are automatically provided by the ECS task metadata endpoint and rotated by AWS every few hours.

### Secret Injection

The ECS-native approach replaces External Secrets Operator or the Secrets Store CSI Driver:

```
Secrets Manager → ECS Execution Role reads at task start → Injected as DB_PASSWORD env var
```

```hcl
# In Task Definition
secrets = [
  {
    name      = "DB_PASSWORD"
    valueFrom = "arn:aws:secretsmanager:us-east-1:123:secret:golden-path/dev/db-password"
  }
]
```

The application reads `process.env.DB_PASSWORD` (or `os.environ['DB_PASSWORD']`) — no AWS SDK calls, no secret management code in the app.

To rotate: `aws secretsmanager put-secret-value --secret-id golden-path/dev/db-password --secret-string 'newpass'` then force a new ECS deployment.

### Auto Scaling (= K8s HPA)

```
CloudWatch metric: ECSServiceAverageCPUUtilization
  ↓ > 60% for 60 seconds
Application Auto Scaling increases DesiredCount
  ↓ New Fargate tasks launched (Spot preferred)
  ↓ ALB automatically routes traffic to new tasks
  
CPU drops below 60% for 300 seconds
  ↓ Application Auto Scaling decreases DesiredCount
```

### 4 Golden Signals Dashboard

| Signal | Source Metric | Dashboard Panel |
|---|---|---|
| **Latency** | `ALB TargetResponseTime` | p50 / p95 / p99 line chart |
| **Traffic** | `ALB RequestCount` | Requests/min time series |
| **Errors** | `ALB HTTPCode_Target_5XX_Count` | 4xx + 5xx counts |
| **Saturation** | `ECS CPUUtilization` + `MemoryUtilization` | % utilization with scale-out threshold annotations |

---

## Cost Breakdown (us-east-1, Dev workload)

| Service | Config | Estimated Cost |
|---|---|---|
| ECS Cluster | Control plane | **FREE** |
| Fargate Spot | 1 task × 0.25 vCPU × 512 MB | ~$1–3/mo |
| Fargate On-Demand | 1 task × 0.25 vCPU × 512 MB | ~$5–7/mo |
| ALB | 1 ALB, low traffic | ~$6/mo |
| NAT Gateway | 1 NAT, ~1 GB/day | ~$33/mo |
| S3 (state + data) | < 1 GB | FREE (12 mo) |
| DynamoDB (lock) | On-demand, negligible ops | FREE (always) |
| Secrets Manager | 1 secret | $0.40/mo (after 30-day trial) |
| CloudWatch | Basic metrics + 1 dashboard | FREE |
| VPC / Subnets / IGW | — | **FREE** |

**💡 Biggest cost item: NAT Gateway (~$33/mo)**
For a zero-cost dev setup, set `enable_nat_gateway = false` in the networking module. Fargate will use the VPC interface endpoints (ECR, Secrets Manager, CloudWatch) for AWS API calls and the S3 gateway endpoint for image layers — eliminating the NAT Gateway entirely.

---

## Rotating the DB Password

```bash
# Update the secret value
aws secretsmanager put-secret-value \
  --secret-id "golden-path/dev/db-password" \
  --secret-string "my-new-secure-password"

# Force ECS to restart tasks with the new secret
aws ecs update-service \
  --cluster golden-path-dev-cluster \
  --service golden-path-dev-hello-world-svc \
  --force-new-deployment
```

---

## GitHub Actions Setup

1. Create an IAM OIDC Identity Provider for `token.actions.githubusercontent.com`
2. Create an IAM role with a trust policy scoped to your repo
3. Add these GitHub Secrets to your repository:

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | ARN of the OIDC-federated IAM role |
| `AWS_REGION` | `us-east-1` |
| `TF_STATE_BUCKET` | S3 bucket name from bootstrap output |
| `TF_STATE_DYNAMODB` | DynamoDB table name from bootstrap output |
| `ECS_CLUSTER_NAME` | From `terraform output ecs_cluster_name` |
| `ECS_SERVICE_NAME` | From `terraform output ecs_service_name` |
