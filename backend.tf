# ==============================================================================
# Remote State Backend
# ------------------------------------------------------------------------------
# IMPORTANT: Run bootstrap/ first, then replace YOUR_ACCOUNT_ID below with the
# 12-digit AWS account ID printed in the bootstrap output (state_bucket value).
# After editing, run: terraform init
# ==============================================================================

terraform {
  backend "s3" {
    bucket         = "golden-path-tfstate-825566110381-ux3krriu"
    key            = "golden-path/dev/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "golden-path-terraform-locks"
  }
}
