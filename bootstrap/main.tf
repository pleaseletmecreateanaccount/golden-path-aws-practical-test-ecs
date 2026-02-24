# ==============================================================================
# STEP 0 — Bootstrap (Run Once Before Everything Else)
# Creates the S3 bucket + DynamoDB table that stores Terraform state.
#
# Usage:
#   cd bootstrap/
#   terraform init && terraform apply
#   Copy the "backend_config" output into ../backend.tf
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Bootstrap itself uses LOCAL state intentionally (chicken-and-egg problem)
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project identifier used in resource names"
  type        = string
  default     = "golden-path"
}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------------------------
# S3 Bucket — Remote State Storage
# Cost note: S3 Standard is free for 5 GB / 12 months (new accounts).
#            State files are tiny (KBs) so this effectively costs nothing.
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true # Never accidentally delete state
  }

  tags = {
    Name    = "${var.project_name}-tfstate"
    Purpose = "Terraform remote state"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled" # Enables state recovery after bad applies
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # S3-managed keys — no cost
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# DynamoDB Table — State Locking
# Cost note: DynamoDB free tier is always free (25 GB + 25 WCU/RCU).
#            State lock operations are trivially small vs. that limit.
# ------------------------------------------------------------------------------

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "${var.project_name}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST" # Only pay per op; free tier covers lock ops
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name    = "${var.project_name}-tfstate-lock"
    Purpose = "Terraform state locking"
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "dynamodb_table" {
  value = aws_dynamodb_table.tfstate_lock.name
}

output "backend_config_snippet" {
  description = "Paste this block into the root-level backend.tf, then run: terraform init -migrate-state"
  value       = <<-EOT

    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.tfstate.bucket}"
        key            = "golden-path/dev/terraform.tfstate"
        region         = "${var.aws_region}"
        dynamodb_table = "${aws_dynamodb_table.tfstate_lock.name}"
        encrypt        = true
      }
    }

  EOT
}
