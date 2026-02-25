# ==============================================================================
# STEP 0 — Bootstrap (Run Once Before Everything Else)
# Creates the S3 bucket and DynamoDB table for Terraform remote state.
#
# DynamoDB table is used for state locking to prevent concurrent operations.
#
# Usage:
#   cd bootstrap/
#   terraform init
#   terraform apply
#   Copy the "backend_config_snippet" output into ../backend.tf
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "random" {}

variable "aws_region" {
  description = "AWS region — must match the region in backend.tf and terraform.tfvars"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "aws-practical-test"
  type        = string
  default     = "golden-path"
}

data "aws_caller_identity" "current" {}

resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}-${random_string.bucket_suffix.result}"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "${var.project_name}-tfstate"
    Purpose = "Terraform remote state"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
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

resource "aws_dynamodb_table" "terraform_locks" {
  name           = "${var.project_name}-terraform-locks"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "${var.project_name}-terraform-locks"
    Purpose = "Terraform state locking"
  }
}

output "state_bucket" {
  description = "S3 bucket name — use this in backend.tf"
  value       = aws_s3_bucket.tfstate.bucket
}

output "backend_config_snippet" {
  description = "Copy this into your backend.tf"
  value = <<-EOT
bucket         = "${aws_s3_bucket.tfstate.bucket}"
key            = "terraform.tfstate"
region         = var.aws_region
encrypt        = true
dynamodb_table = aws_dynamodb_table.terraform_locks.name
  EOT
}
