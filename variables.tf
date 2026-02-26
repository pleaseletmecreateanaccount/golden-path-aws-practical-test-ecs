# ==============================================================================
# Root Input Variables
# ==============================================================================

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Short project name used as a prefix across all resource names"
  type        = string
  default     = "golden-path"
}

variable "environment" {
  description = "Deployment environment (dev | staging | prod)"
  type        = string
  default     = "dev"
}

# --- Networking ---------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (ALB lives here)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# --- App ----------------------------------------------------------------------

variable "app_name" {
  description = "Name of the Hello World application"
  type        = string
  default     = "hello-world"
}

variable "app_image" {
  description = "Docker image to deploy (public Hello World)"
  type        = string
  default     = "nginx:1.27-alpine" # Minimal, public, no auth required
}

variable "app_port" {
  description = "Container port the app listens on"
  type        = number
  default     = 80
}

variable "app_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)"
  type        = number
  default     = 256 # Minimum Fargate unit — lowest cost
}

variable "app_memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 512 # Minimum paired with 256 CPU — lowest cost
}

variable "app_desired_count" {
  description = "Desired number of ECS tasks"
  type        = number
  default     = 2 # Min 2 for HA across 2 AZs
}

variable "app_min_count" {
  description = "Minimum tasks for Auto Scaling"
  type        = number
  default     = 1
}

variable "app_max_count" {
  description = "Maximum tasks for Auto Scaling"
  type        = number
  default     = 4
}

variable "cpu_scale_target" {
  description = "Target CPU % before scaling out (analogous to HPA in K8s)"
  type        = number
  default     = 60
}

# --- S3 app bucket ------------------------------------------------------------

variable "app_s3_bucket_name" {
  description = "S3 bucket the app task role can access (for IRSA-equivalent)"
  type        = string
  default     = "" # Defaults to project-name-app-data-accountId if empty
}

# --- Secrets ------------------------------------------------------------------

variable "db_password_secret_name" {
  description = "Name of the Secrets Manager secret holding the DB password"
  type        = string
  default     = "golden-path/dev/db-password"
}
