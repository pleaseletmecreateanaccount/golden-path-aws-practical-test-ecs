# ==============================================================================
# Remote State Backend
# ------------------------------------------------------------------------------
# IMPORTANT: Run bootstrap/ first, then replace the placeholder bucket name
# with the actual value printed in the bootstrap output.
# After editing, run: terraform init  (or terraform init -migrate-state)
# ==============================================================================

terraform {
  backend "s3" {
    bucket         = "golden-path-tfstate-REPLACE_WITH_YOUR_ACCOUNT_ID"
    key            = "golden-path/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "golden-path-tfstate-lock"
    encrypt        = true
  }
}
