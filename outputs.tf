# ==============================================================================
# Root Outputs
# ==============================================================================

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = module.ecs.alb_dns_name
}

output "alb_url" {
  description = "Full HTTP URL to reach the Hello World app"
  value       = "http://${module.ecs.alb_dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = module.ecs.service_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (Fargate tasks run here)"
  value       = module.networking.private_subnet_ids
}

output "app_s3_bucket" {
  description = "S3 bucket the ECS task role can access (no static keys)"
  value       = aws_s3_bucket.app_data.bucket
}

output "db_password_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the DB password"
  value       = module.secrets.secret_arn
  sensitive   = true
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch Dashboard URL (4 Golden Signals)"
  value       = module.observability.dashboard_url
}
