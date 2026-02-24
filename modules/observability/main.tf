# ==============================================================================
# Module: Observability
#
# CloudWatch Dashboard — The 4 Golden Signals (Google SRE Book)
# ┌─────────────────────────────────────────────────────────┐
# │  1. LATENCY    — ALB TargetResponseTime (p50, p95, p99)│
# │  2. TRAFFIC    — ALB RequestCount per minute           │
# │  3. ERRORS     — ALB 5xx + 4xx HTTP responses          │
# │  4. SATURATION — ECS CPU % + Memory % utilization      │
# └─────────────────────────────────────────────────────────┘
#
# Additional panels:
#   - ECS Running Task count (detect unexpected scale-in)
#   - ALB Healthy Host count (detect failed health checks)
#   - Auto Scaling activity
#
# Cost: CloudWatch free tier = 10 custom metrics, 3 dashboards, 1M API calls.
#       Container Insights metrics DO have per-metric charges beyond free tier.
#       Standard ALB metrics are free. Set containerInsights=disabled for zero cost.
# ==============================================================================

variable "name_prefix"    { type = string }
variable "region"         { type = string }
variable "ecs_cluster"    { type = string }
variable "ecs_service"    { type = string }
variable "alb_arn_suffix" { type = string }
variable "tg_arn_suffix"  { type = string }

# ------------------------------------------------------------------------------
# CloudWatch Alarms — alerting on Golden Signals
# ------------------------------------------------------------------------------

# LATENCY alarm — p95 latency > 1 second
resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${var.name_prefix}-latency-p95-high"
  alarm_description   = "Golden Signal: Latency — p95 response time above 1s"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  statistic           = "p95"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1.0       # 1 second
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Name = "${var.name_prefix}-latency-alarm" }
}

# ERROR RATE alarm — 5xx errors > 5%
resource "aws_cloudwatch_metric_alarm" "error_rate_5xx" {
  alarm_name          = "${var.name_prefix}-5xx-error-rate-high"
  alarm_description   = "Golden Signal: Errors — HTTP 5xx rate elevated"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Name = "${var.name_prefix}-5xx-alarm" }
}

# SATURATION alarm — CPU > 80%
resource "aws_cloudwatch_metric_alarm" "cpu_saturation" {
  alarm_name          = "${var.name_prefix}-cpu-saturation-high"
  alarm_description   = "Golden Signal: Saturation — ECS CPU utilization above 80%"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions = {
    ClusterName = var.ecs_cluster
    ServiceName = var.ecs_service
  }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Name = "${var.name_prefix}-cpu-alarm" }
}

# SATURATION alarm — Memory > 80%
resource "aws_cloudwatch_metric_alarm" "memory_saturation" {
  alarm_name          = "${var.name_prefix}-memory-saturation-high"
  alarm_description   = "Golden Signal: Saturation — ECS Memory utilization above 80%"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions = {
    ClusterName = var.ecs_cluster
    ServiceName = var.ecs_service
  }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Name = "${var.name_prefix}-memory-alarm" }
}

# TRAFFIC alarm — zero requests (dead service detection)
resource "aws_cloudwatch_metric_alarm" "no_traffic" {
  alarm_name          = "${var.name_prefix}-zero-traffic"
  alarm_description   = "Golden Signal: Traffic — No requests received (possible service down)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "RequestCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "LessThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  tags = { Name = "${var.name_prefix}-no-traffic-alarm" }
}

# ------------------------------------------------------------------------------
# CloudWatch Dashboard — 4 Golden Signals
# Layout: 2-column grid, 6-hour default time range
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "golden_signals" {
  dashboard_name = "${var.name_prefix}-golden-signals"

  dashboard_body = jsonencode({
    widgets = [

      # ── Row 1: Header Labels ────────────────────────────────────────────────

      {
        type   = "text"
        x      = 0; y = 0; width = 24; height = 1
        properties = {
          markdown = "# ${var.name_prefix} — The 4 Golden Signals Dashboard\n**Cluster:** `${var.ecs_cluster}` | **Service:** `${var.ecs_service}` | **Region:** `${var.region}`"
        }
      },

      # ── Row 2: LATENCY ──────────────────────────────────────────────────────
      # Signal: How long requests take — key indicator of user experience

      {
        type   = "text"
        x      = 0; y = 1; width = 24; height = 1
        properties = {
          markdown = "## 🕐 Latency — How long it takes to service a request"
        }
      },
      {
        type   = "metric"
        x      = 0; y = 2; width = 12; height = 6
        properties = {
          title  = "ALB Response Time (p50 / p95 / p99)"
          view   = "timeSeries"
          region = var.region
          period = 60
          stat   = "p50"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix,
              { stat = "p50", label = "p50 Latency", color = "#2ca02c" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix,
              { stat = "p95", label = "p95 Latency", color = "#ff7f0e" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix,
              { stat = "p99", label = "p99 Latency", color = "#d62728" }]
          ]
          yAxis = { left = { label = "Seconds", min = 0 } }
          annotations = {
            horizontal = [{ value = 1.0, label = "1s SLO", color = "#d62728" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12; y = 2; width = 12; height = 6
        properties = {
          title  = "ALB Response Time Distribution"
          view   = "timeSeries"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix,
              { stat = "Average", label = "Avg Latency" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix,
              { stat = "Maximum", label = "Max Latency" }]
          ]
          yAxis = { left = { label = "Seconds", min = 0 } }
        }
      },

      # ── Row 3: TRAFFIC ──────────────────────────────────────────────────────
      # Signal: How much demand is being placed on the system

      {
        type   = "text"
        x      = 0; y = 8; width = 24; height = 1
        properties = {
          markdown = "## 📈 Traffic — How much demand is on your system"
        }
      },
      {
        type   = "metric"
        x      = 0; y = 9; width = 12; height = 6
        properties = {
          title  = "Request Count per Minute"
          view   = "timeSeries"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix,
              { stat = "Sum", label = "Total Requests/min", color = "#1f77b4" }]
          ]
          yAxis = { left = { label = "Requests", min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 12; y = 9; width = 12; height = 6
        properties = {
          title  = "Active Connections + New Connections"
          view   = "timeSeries"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "ActiveConnectionCount", "LoadBalancer", var.alb_arn_suffix,
              { stat = "Average", label = "Active Connections" }],
            ["AWS/ApplicationELB", "NewConnectionCount", "LoadBalancer", var.alb_arn_suffix,
              { stat = "Sum", label = "New Connections/min" }]
          ]
        }
      },

      # ── Row 4: ERRORS ───────────────────────────────────────────────────────
      # Signal: Rate of requests that fail

      {
        type   = "text"
        x      = 0; y = 15; width = 24; height = 1
        properties = {
          markdown = "## 🚨 Errors — Rate of requests that fail"
        }
      },
      {
        type   = "metric"
        x      = 0; y = 16; width = 12; height = 6
        properties = {
          title  = "HTTP Error Responses (4xx / 5xx)"
          view   = "timeSeries"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix,
              { stat = "Sum", label = "5xx Errors (Server)", color = "#d62728" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", var.alb_arn_suffix,
              { stat = "Sum", label = "4xx Errors (Client)", color = "#ff7f0e" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix,
              { stat = "Sum", label = "5xx from ALB", color = "#9467bd" }]
          ]
          yAxis = { left = { label = "Error Count", min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 12; y = 16; width = 12; height = 6
        properties = {
          title  = "Failed Target Health Checks"
          view   = "timeSeries"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.tg_arn_suffix,
              "LoadBalancer", var.alb_arn_suffix,
              { stat = "Minimum", label = "Healthy Targets", color = "#2ca02c" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", var.tg_arn_suffix,
              "LoadBalancer", var.alb_arn_suffix,
              { stat = "Maximum", label = "Unhealthy Targets", color = "#d62728" }]
          ]
          yAxis = { left = { label = "Host Count", min = 0 } }
        }
      },

      # ── Row 5: SATURATION ───────────────────────────────────────────────────
      # Signal: How full / constrained the service is

      {
        type   = "text"
        x      = 0; y = 22; width = 24; height = 1
        properties = {
          markdown = "## 📊 Saturation — How full or constrained your service is"
        }
      },
      {
        type   = "metric"
        x      = 0; y = 23; width = 12; height = 6
        properties = {
          title  = "ECS CPU Utilization %"
          view   = "timeSeries"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization",
              "ClusterName", var.ecs_cluster, "ServiceName", var.ecs_service,
              { stat = "Average", label = "CPU Avg %", color = "#ff7f0e" }],
            ["AWS/ECS", "CPUUtilization",
              "ClusterName", var.ecs_cluster, "ServiceName", var.ecs_service,
              { stat = "Maximum", label = "CPU Max %", color = "#d62728" }]
          ]
          yAxis = { left = { label = "CPU %", min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = 60, label = "Scale-out threshold", color = "#ff7f0e" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12; y = 23; width = 12; height = 6
        properties = {
          title  = "ECS Memory Utilization %"
          view   = "timeSeries"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ECS", "MemoryUtilization",
              "ClusterName", var.ecs_cluster, "ServiceName", var.ecs_service,
              { stat = "Average", label = "Memory Avg %", color = "#1f77b4" }],
            ["AWS/ECS", "MemoryUtilization",
              "ClusterName", var.ecs_cluster, "ServiceName", var.ecs_service,
              { stat = "Maximum", label = "Memory Max %", color = "#9467bd" }]
          ]
          yAxis = { left = { label = "Memory %", min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = 70, label = "Scale-out threshold", color = "#ff7f0e" }]
          }
        }
      },

      # ── Row 6: ECS Scaling Activity ─────────────────────────────────────────

      {
        type   = "text"
        x      = 0; y = 29; width = 24; height = 1
        properties = {
          markdown = "## ⚖️ ECS Service Health + Auto Scaling Activity"
        }
      },
      {
        type   = "metric"
        x      = 0; y = 30; width = 12; height = 6
        properties = {
          title  = "ECS Running Task Count"
          view   = "timeSeries"
          region = var.region
          period = 60
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount",
              "ClusterName", var.ecs_cluster, "ServiceName", var.ecs_service,
              { stat = "Average", label = "Running Tasks", color = "#2ca02c" }]
          ]
          yAxis = { left = { label = "Task Count", min = 0 } }
        }
      },
      {
        type   = "alarm"
        x      = 12; y = 30; width = 12; height = 6
        properties = {
          title  = "Alarm Status — Golden Signal Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.latency_p95.arn,
            aws_cloudwatch_metric_alarm.error_rate_5xx.arn,
            aws_cloudwatch_metric_alarm.cpu_saturation.arn,
            aws_cloudwatch_metric_alarm.memory_saturation.arn,
            aws_cloudwatch_metric_alarm.no_traffic.arn,
          ]
        }
      }

    ]
  })
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "dashboard_name" { value = aws_cloudwatch_dashboard.golden_signals.dashboard_name }
output "dashboard_url"  {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.golden_signals.dashboard_name}"
}
