# ==============================================================================
# Module: ECS Fargate
#
# Resources:
#   - ECS Cluster (with Container Insights for observability)
#   - CloudWatch Log Group for container logs
#   - Task Definition (Fargate) with:
#       * nginx Hello World container
#       * DB_PASSWORD injected from Secrets Manager (no code change needed)
#       * Task Role bound (S3 access via metadata — no static keys)
#   - ECS Service using FARGATE + FARGATE_SPOT capacity providers
#       * Spot-first strategy with On-Demand fallback (cost + reliability)
#   - Application Load Balancer (public-facing, in public subnets)
#   - ALB Target Group + Listener (HTTP:80)
#   - Application Auto Scaling (CPU-based — equivalent to K8s HPA)
#   - Security Groups (least-privilege)
# ==============================================================================

# ------------------------------------------------------------------------------
# Variables
# ------------------------------------------------------------------------------

variable "name_prefix"             { type = string }
variable "region"                  { type = string }
variable "vpc_id"                  { type = string }
variable "public_subnet_ids"       { type = list(string) }
variable "private_subnet_ids"      { type = list(string) }
variable "app_name"                { type = string }
variable "app_image"               { type = string }
variable "app_port"                { type = number }
variable "app_cpu"                 { type = number }
variable "app_memory"              { type = number }
variable "app_desired_count"       { type = number }
variable "app_min_count"           { type = number }
variable "app_max_count"           { type = number }
variable "cpu_scale_target"        { type = number }
variable "task_execution_role_arn" { type = string }
variable "task_role_arn"           { type = string }
variable "secret_arn"              { type = string }
variable "db_password_secret_name" { type = string }

# ------------------------------------------------------------------------------
# CloudWatch Log Group
# Free tier: 5 GB ingestion + 5 GB storage free per month
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name_prefix}/${var.app_name}"
  retention_in_days = 7 # Keep logs for 7 days only to stay within free tier

  tags = { Name = "${var.name_prefix}-${var.app_name}-logs" }
}

# ------------------------------------------------------------------------------
# ECS Cluster
# Container Insights adds CloudWatch metrics for the 4 Golden Signals dashboard
# Cost: Container Insights has per-metric charges beyond free tier. For zero cost
#       set value = "disabled". Enabled here for the senior observability requirement.
# ------------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.name_prefix}-cluster" }
}

# Enable FARGATE and FARGATE_SPOT capacity providers on this cluster
# This is what enables the Spot-first + On-Demand fallback strategy
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Default strategy: try Spot first, fall back to On-Demand
  # FARGATE_SPOT is up to 70% cheaper than standard FARGATE
  # If Spot capacity is unavailable, ECS automatically places task on FARGATE
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 4  # 80% of tasks → Spot
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1  # 20% of tasks → On-Demand (baseline reliability)
    base              = 1  # Always keep at least 1 On-Demand task running
  }
}

# ------------------------------------------------------------------------------
# ECS Task Definition
# ------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-${var.app_name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # Required for Fargate
  cpu                      = var.app_cpu
  memory                   = var.app_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn # App code uses this for S3 — no static keys

  container_definitions = jsonencode([
    {
      name      = var.app_name
      image     = var.app_image
      essential = true

      portMappings = [
        {
          containerPort = var.app_port
          hostPort      = var.app_port
          protocol      = "tcp"
        }
      ]

      # -----------------------------------------------------------------------
      # Secret Injection via Secrets Manager
      # ECS fetches the secret value at task startup (using execution role) and
      # injects it as an environment variable. The app code just reads DB_PASSWORD
      # from the environment — no AWS SDK calls required.
      #
      # This is equivalent to External Secrets Operator or CSI Secrets Driver
      # in Kubernetes, but native to ECS with zero additional infrastructure.
      # -----------------------------------------------------------------------
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = var.secret_arn
        }
      ]

      # Regular environment variables (non-sensitive)
      environment = [
        { name = "APP_ENV",      value = "production" },
        { name = "APP_NAME",     value = var.app_name },
        { name = "AWS_REGION",   value = var.region }
        # DB_PASSWORD is injected from Secrets Manager above
        # S3 credentials are NOT needed — Task Role provides them automatically
      ]

      # Send stdout/stderr to CloudWatch Logs
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      # Health check so ECS knows when the container is ready
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.app_port}/ || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    }
  ])

  tags = { Name = "${var.name_prefix}-${var.app_name}-task" }
}

# ------------------------------------------------------------------------------
# Security Groups
# ------------------------------------------------------------------------------

# ALB Security Group — accepts HTTP from anywhere (public-facing)
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-sg-alb"
  description = "Allow HTTP inbound to ALB from internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg-alb" }
}

# ECS Task Security Group — only accepts traffic from the ALB
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name_prefix}-sg-ecs-tasks"
  description = "Allow inbound from ALB to ECS tasks only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Container port from ALB only"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound (for ECR pulls, Secrets Manager, S3 via VPC endpoints)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg-ecs-tasks" }
}

# ------------------------------------------------------------------------------
# Application Load Balancer
# Cost: ALB has hourly charges (~$0.008/hr = ~$5.76/mo). Not in free tier.
#       For zero cost in dev, set enable_alb=false and use ECS Service Connect.
# ------------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false # Public-facing — internet traffic hits this
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # Access logs to S3 (optional; disabled by default to save cost)
  # enable_deletion_protection = false # OK for dev

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name_prefix}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Required for Fargate (awsvpc network mode)

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.name_prefix}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ------------------------------------------------------------------------------
# ECS Service
# ------------------------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name                               = "${var.name_prefix}-${var.app_name}-svc"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = var.app_desired_count
  health_check_grace_period_seconds  = 30

  # Use capacity provider strategy (Spot-first + On-Demand fallback)
  # Overrides the cluster default with explicit weights per service
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 4   # 80% Spot — low cost
    base              = 0
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1   # 20% On-Demand — guaranteed capacity
    base              = 1   # At least 1 On-Demand task always running
  }

  network_configuration {
    subnets          = var.private_subnet_ids  # Tasks in private subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false # Private subnet; uses NAT/VPC endpoints
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.app_name
    container_port   = var.app_port
  }

  # Rolling deployment — ECS replaces tasks gradually (zero downtime)
  deployment_circuit_breaker {
    enable   = true
    rollback = true # Auto-rollback if new deployment fails health checks
  }

  deployment_controller {
    type = "ECS" # Native ECS rolling deployments (use CODE_DEPLOY for blue/green)
  }

  # Ensure load balancer + task role exist before service creation
  depends_on = [
    aws_lb_listener.http,
  ]

  tags = { Name = "${var.name_prefix}-${var.app_name}-svc" }

  lifecycle {
    # Allow external Auto Scaling to manage desired_count without Terraform drift
    ignore_changes = [desired_count]
  }
}

# ------------------------------------------------------------------------------
# Application Auto Scaling (Equivalent to Kubernetes HPA)
#
# Kubernetes HPA scales Pods based on CPU/memory metrics.
# ECS Application Auto Scaling does the same for Tasks:
#   - CloudWatch monitors ECSServiceAverageCPUUtilization
#   - When CPU > target%, Application Auto Scaling increases desired_count
#   - When CPU < target%, it scales down (with cooldown to prevent thrashing)
# ------------------------------------------------------------------------------

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.app_max_count
  min_capacity       = var.app_min_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.app]
}

# Scale OUT when CPU > target (analogous to HPA scaleUp)
resource "aws_appautoscaling_policy" "cpu_scale_out" {
  name               = "${var.name_prefix}-cpu-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = var.cpu_scale_target  # Scale when CPU > this %
    scale_in_cooldown  = 300  # Wait 5 min before scaling in (prevent thrashing)
    scale_out_cooldown = 60   # Scale out quickly when load spikes
  }
}

# Memory-based scaling (bonus — covers Memory saturation Golden Signal)
resource "aws_appautoscaling_policy" "memory_scale_out" {
  name               = "${var.name_prefix}-memory-scale-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }

    target_value       = 70   # Scale when memory > 70%
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "cluster_name"   { value = aws_ecs_cluster.main.name }
output "cluster_arn"    { value = aws_ecs_cluster.main.arn }
output "service_name"   { value = aws_ecs_service.app.name }
output "alb_dns_name"   { value = aws_lb.main.dns_name }
output "alb_arn"        { value = aws_lb.main.arn }
output "alb_arn_suffix" { value = aws_lb.main.arn_suffix }  # Used by CloudWatch dashboard
output "tg_arn_suffix"  { value = aws_lb_target_group.app.arn_suffix }
output "log_group_name" { value = aws_cloudwatch_log_group.app.name }
