# ==============================================================================
# Remote State Backend
# ------------------------------------------------------------------------------
# IMPORTANT: Run bootstrap/ first, then replace YOUR_ACCOUNT_ID below with the
# 12-digit AWS account ID printed in the bootstrap output (state_bucket value).
# After editing, run: terraform init
#
# Note: dynamodb_table is deprecated in AWS provider >= 5.x
#       use_lockfile = true is the modern equivalent (uses S3 native locking)
# ==============================================================================

terraform {
  backend "s3" {
    bucket       = "golden-path-tfstate-825566110381-ux3krriu"
    key          = "golden-path/dev/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
