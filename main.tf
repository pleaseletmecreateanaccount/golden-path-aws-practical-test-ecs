# ==============================================================================
# Root Orchestrator — wires all modules together
# ==============================================================================

resource "random_string" "s3_suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name

  # S3 bucket for app data (IRSA-equivalent access) — add random suffix to avoid name collisions
  app_s3_bucket = var.app_s3_bucket_name != "" ? var.app_s3_bucket_name : "${local.name_prefix}-app-data-${local.account_id}-${random_string.s3_suffix.result}"
}

# ------------------------------------------------------------------------------
# Module: Networking
# VPC + 2 Public Subnets + 2 Private Subnets + NAT Gateway + IGW
# ------------------------------------------------------------------------------

module "networking" {
  source = "./modules/networking"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  region               = local.region
}

# ------------------------------------------------------------------------------
# Module: IAM
# ECS Task Execution Role + Task Role (S3 access without static keys)
# ------------------------------------------------------------------------------

module "iam" {
  source = "./modules/iam"

  name_prefix   = local.name_prefix
  account_id    = local.account_id
  region        = local.region
  app_s3_bucket = local.app_s3_bucket
  secret_arn    = module.secrets.secret_arn
}

# ------------------------------------------------------------------------------
# Module: Secrets Manager
# Stores DB password; ECS task pulls it at runtime via Secrets Manager injection
# ------------------------------------------------------------------------------

module "secrets" {
  source = "./modules/secrets"

  name_prefix             = local.name_prefix
  db_password_secret_name = var.db_password_secret_name
}

# ------------------------------------------------------------------------------
# Module: S3 App Data Bucket
# The bucket the ECS task role has read/write access to (no static keys)
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "app_data" {
  bucket = local.app_s3_bucket

  tags = {
    Name    = local.app_s3_bucket
    Purpose = "Application data bucket accessed via ECS Task Role"
  }
}

resource "aws_s3_bucket_public_access_block" "app_data" {
  bucket                  = aws_s3_bucket.app_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ------------------------------------------------------------------------------
# Module: ECS Fargate
# Cluster + Service + Task Definition + ALB + Auto Scaling
# ------------------------------------------------------------------------------

module "ecs" {
  source = "./modules/ecs"

  name_prefix             = local.name_prefix
  region                  = local.region
  vpc_id                  = module.networking.vpc_id
  public_subnet_ids       = module.networking.public_subnet_ids
  private_subnet_ids      = module.networking.private_subnet_ids
  app_name                = var.app_name
  app_image               = var.app_image
  app_port                = var.app_port
  app_cpu                 = var.app_cpu
  app_memory              = var.app_memory
  app_desired_count       = var.app_desired_count
  app_min_count           = var.app_min_count
  app_max_count           = var.app_max_count
  cpu_scale_target        = var.cpu_scale_target
  task_execution_role_arn = module.iam.task_execution_role_arn
  task_role_arn           = module.iam.task_role_arn
  secret_arn              = module.secrets.secret_arn
  db_password_secret_name = var.db_password_secret_name
}

# ------------------------------------------------------------------------------
# Module: Observability
# CloudWatch Dashboard tracking the 4 Golden Signals
# ------------------------------------------------------------------------------

module "observability" {
  source = "./modules/observability"

  name_prefix    = local.name_prefix
  region         = local.region
  ecs_cluster    = module.ecs.cluster_name
  ecs_service    = module.ecs.service_name
  alb_arn_suffix = module.ecs.alb_arn_suffix
  tg_arn_suffix  = module.ecs.tg_arn_suffix
}
