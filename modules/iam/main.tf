# ==============================================================================
# Module: IAM
#
# ECS Task Execution Role:
#   - Grants ECS/Fargate control plane permission to pull images, write logs,
#     and fetch secrets from Secrets Manager at launch time.
#
# ECS Task Role (ECS equivalent of IRSA):
#   - Assumed BY the running container process.
#   - Grants S3 read/write access WITHOUT static access keys.
#   - AWS SDK inside the container automatically uses the metadata endpoint
#     (169.254.170.2) to get rotating credentials — same security model as IRSA.
#
# Why this equals IRSA for ECS:
#   Kubernetes IRSA uses OIDC federation + K8s service accounts.
#   ECS Task Role uses IAM task role binding + ECS metadata credential provider.
#   Both result in short-lived, automatically-rotated credentials injected into
#   the runtime environment — no static keys, no secrets to rotate manually.
# ==============================================================================

variable "name_prefix"      { type = string }
variable "account_id"       { type = string }
variable "region"           { type = string }
variable "app_s3_bucket"    { type = string }
variable "secret_arn"       { type = string }

# ------------------------------------------------------------------------------
# ECS Task Execution Role
# Used by the ECS agent (not the app code) to bootstrap the container
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    sid     = "ECSTasksAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name_prefix}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  description        = "Allows ECS agent to pull images, write logs, fetch secrets"
}

# AWS managed policy covering ECR pull + CloudWatch Logs
resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Additional: allow execution role to read the DB password secret
# (This is needed so ECS can inject the secret as an env var at container start)
data "aws_iam_policy_document" "task_execution_secrets" {
  statement {
    sid    = "ReadDBPasswordSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [var.secret_arn]
  }
}

resource "aws_iam_policy" "task_execution_secrets" {
  name        = "${var.name_prefix}-task-execution-secrets-policy"
  description = "Allow ECS execution role to read Secrets Manager for container injection"
  policy      = data.aws_iam_policy_document.task_execution_secrets.json
}

resource "aws_iam_role_policy_attachment" "task_execution_secrets" {
  role       = aws_iam_role.task_execution.name
  policy_arn = aws_iam_policy.task_execution_secrets.arn
}

# ------------------------------------------------------------------------------
# ECS Task Role (ECS equivalent of Kubernetes IRSA)
#
# This role is assumed by the APPLICATION PROCESS inside the container.
# No access keys are needed — the ECS metadata endpoint provides temporary
# credentials that are automatically rotated by AWS.
#
# The app accesses S3 using the AWS SDK with zero config:
#   boto3.client('s3')  → picks up credentials from instance metadata
#   aws.NewSession()    → same auto-discovery via credential chain
# ------------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  description        = "Assumed by the app container — grants S3 access without static keys"
}

# Minimal S3 permissions: read/write only to the app's own bucket + prefix
data "aws_iam_policy_document" "task_s3" {
  # List the bucket (needed for many SDK operations)
  statement {
    sid    = "ListAppBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = ["arn:aws:s3:::${var.app_s3_bucket}"]
  }

  # Read / write objects in the bucket
  statement {
    sid    = "ReadWriteAppBucketObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${var.app_s3_bucket}/*"]
  }
}

resource "aws_iam_policy" "task_s3" {
  name        = "${var.name_prefix}-task-s3-policy"
  description = "S3 access for ECS task role (no static keys — uses metadata endpoint)"
  policy      = data.aws_iam_policy_document.task_s3.json
}

resource "aws_iam_role_policy_attachment" "task_s3" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.task_s3.arn
}

# Also allow the task to READ the secret at runtime (if app code queries it directly)
data "aws_iam_policy_document" "task_secrets_read" {
  statement {
    sid    = "ReadDBPasswordAtRuntime"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.secret_arn]
  }
}

resource "aws_iam_policy" "task_secrets_read" {
  name        = "${var.name_prefix}-task-secrets-read-policy"
  description = "Allow container process to read DB password from Secrets Manager"
  policy      = data.aws_iam_policy_document.task_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "task_secrets_read" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.task_secrets_read.arn
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "task_execution_role_arn" { value = aws_iam_role.task_execution.arn }
output "task_role_arn"           { value = aws_iam_role.task.arn }
output "task_execution_role_name" { value = aws_iam_role.task_execution.name }
output "task_role_name"           { value = aws_iam_role.task.name }
