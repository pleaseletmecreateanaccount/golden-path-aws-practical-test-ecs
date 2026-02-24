# ==============================================================================
# Module: Secrets Manager
#
# Stores the DB password as a secret. The ECS task definition references this
# ARN in the "secrets" block — ECS automatically injects the value as an
# environment variable at container startup, so the app never needs to call
# the Secrets Manager API itself (though it can if needed).
#
# This is the ECS-native alternative to:
#   - External Secrets Operator (used with Kubernetes)
#   - Secrets Store CSI Driver (used with Kubernetes)
#
# How injection works:
#   Task Definition → secrets: [{ name: "DB_PASSWORD", valueFrom: "<secret_arn>" }]
#   ECS Agent (execution role) → calls secretsmanager:GetSecretValue at startup
#   Container sees → env var DB_PASSWORD=<value>  (no code change needed)
#
# Cost: $0.40/secret/month after 30-day free trial
#       For dev, rotate the secret manually and set recovery_window_in_days=0
#       to avoid costs from leftover secrets.
# ==============================================================================

variable "name_prefix"             { type = string }
variable "db_password_secret_name" { type = string }

variable "initial_db_password" {
  description = "Initial placeholder password. Rotate via AWS Console or CLI after deploy."
  type        = string
  default     = "CHANGE_ME_AFTER_DEPLOY_do-not-use-in-prod"
  sensitive   = true
}

# ------------------------------------------------------------------------------
# Secret: DB Password
# ------------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "db_password" {
  name        = var.db_password_secret_name
  description = "Database password for ${var.name_prefix} application"

  # How long to wait before permanent deletion (set to 0 for dev to save cost)
  recovery_window_in_days = 7

  tags = {
    Name    = var.db_password_secret_name
    Purpose = "Application DB credentials"
  }
}

# Store the initial (placeholder) value
resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.initial_db_password

  # Terraform will NOT overwrite the secret after initial creation.
  # Rotate via: aws secretsmanager put-secret-value --secret-id <name> --secret-string '<new>'
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "secret_arn"  { value = aws_secretsmanager_secret.db_password.arn }
output "secret_name" { value = aws_secretsmanager_secret.db_password.name }
