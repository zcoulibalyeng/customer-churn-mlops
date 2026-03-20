# # ═══════════════════════════════════════════════════════════════
# # Monitoring Module
# #
# # THIS IS WHERE MLOPS BECOMES REAL.
# # Without monitoring, you just have a deployed model.
# # With monitoring, you have a system that heals itself.
# #
# # WHAT WE MONITOR:
# #   1. Endpoint health   → 5xx errors, latency
# #   2. Model quality     → prediction distribution shifts
# #   3. Data drift        → input feature distribution changes
# #   4. Infrastructure    → CPU, memory, invocation count
# #
# # ALERT CHAIN:
# #   CloudWatch Alarm → SNS Topic → Email / PagerDuty / Lambda (retrain)
# # ═══════════════════════════════════════════════════════════════
#
# variable "project_name" { type = string }
# variable "environment" { type = string }
# variable "name_prefix" { type = string }
# variable "sagemaker_endpoint" { type = string }
# variable "alert_email" { type = string }
# variable "enable_monitoring" { type = bool }
# variable "monitoring_bucket" { type = string }
# variable "sagemaker_role_arn" { type = string }
#
# # ─── SNS Topic (Alert Fan-Out) ──────────────────────────────
# # All alarms publish here. SNS fans out to email, Slack, PagerDuty.
# resource "aws_sns_topic" "alerts" {
#   name = "${var.name_prefix}-alerts"
# }
#
# resource "aws_sns_topic_subscription" "email" {
#   topic_arn = aws_sns_topic.alerts.arn
#   protocol  = "email"
#   endpoint  = var.alert_email
# }
#
# # Separate topic for retrain triggers
# resource "aws_sns_topic" "retrain" {
#   name = "${var.name_prefix}-retrain-trigger"
# }
#
# # ─── ALARM 1: High Error Rate (P1 - Wake up) ────────────────
# resource "aws_cloudwatch_metric_alarm" "endpoint_5xx" {
#   alarm_name          = "${var.name_prefix}-endpoint-5xx"
#   comparison_operator = "GreaterThanThreshold"
#   evaluation_periods  = 2
#   metric_name         = "Invocation5XXErrors"
#   namespace           = "AWS/SageMaker"
#   period              = 300  # 5 min windows
#   statistic           = "Sum"
#   threshold           = 10   # More than 10 errors in 5 min = alarm
#
#   dimensions = {
#     EndpointName = var.sagemaker_endpoint
#     VariantName  = "champion"
#   }
#
#   alarm_actions = [aws_sns_topic.alerts.arn]
#   ok_actions    = [aws_sns_topic.alerts.arn]
#
#   alarm_description = "CRITICAL: SageMaker endpoint returning 5xx errors. Check container logs."
#   treat_missing_data = "notBreaching"
# }
#
# # ─── ALARM 2: High Latency (P2 - Investigate) ───────────────
# resource "aws_cloudwatch_metric_alarm" "endpoint_latency" {
#   alarm_name          = "${var.name_prefix}-endpoint-latency-p99"
#   comparison_operator = "GreaterThanThreshold"
#   evaluation_periods  = 3
#   metric_name         = "ModelLatency"
#   namespace           = "AWS/SageMaker"
#   period              = 300
#   extended_statistic  = "p99"
#   threshold           = 100000  # 100ms in microseconds
#
#   dimensions = {
#     EndpointName = var.sagemaker_endpoint
#     VariantName  = "champion"
#   }
#
#   alarm_actions = [aws_sns_topic.alerts.arn]
#
#   alarm_description = "WARNING: p99 latency exceeds 100ms. Check for instance saturation or model bloat."
#   treat_missing_data = "notBreaching"
# }
#
# # ─── ALARM 3: No Invocations (P2 - System down?) ────────────
# resource "aws_cloudwatch_metric_alarm" "no_invocations" {
#   alarm_name          = "${var.name_prefix}-no-invocations"
#   comparison_operator = "LessThanThreshold"
#   evaluation_periods  = 3
#   metric_name         = "Invocations"
#   namespace           = "AWS/SageMaker"
#   period              = 300
#   statistic           = "Sum"
#   threshold           = 1  # Zero invocations for 15 min = alarm
#
#   dimensions = {
#     EndpointName = var.sagemaker_endpoint
#     VariantName  = "champion"
#   }
#
#   alarm_actions = [aws_sns_topic.alerts.arn]
#
#   alarm_description = "WARNING: No invocations for 15 min. Check API Gateway and upstream services."
#   treat_missing_data = "breaching"
# }
#
# # ─── ALARM 4: High CPU (triggers auto-scaling awareness) ────
# resource "aws_cloudwatch_metric_alarm" "high_cpu" {
#   alarm_name          = "${var.name_prefix}-high-cpu"
#   comparison_operator = "GreaterThanThreshold"
#   evaluation_periods  = 3
#   metric_name         = "CPUUtilization"
#   namespace           = "/aws/sagemaker/Endpoints"
#   period              = 300
#   statistic           = "Average"
#   threshold           = 80
#
#   dimensions = {
#     EndpointName = var.sagemaker_endpoint
#     VariantName  = "champion"
#   }
#
#   alarm_actions = [aws_sns_topic.alerts.arn]
#
#   alarm_description = "WARNING: CPU > 80% sustained. Auto-scaling should handle this; verify scaling policy is active."
#   treat_missing_data = "notBreaching"
# }
#
# # ─── CloudWatch Dashboard ───────────────────────────────────
# resource "aws_cloudwatch_dashboard" "mlops" {
#   dashboard_name = "${var.name_prefix}-dashboard"
#
#   dashboard_body = jsonencode({
#     widgets = [
#       {
#         type   = "metric"
#         x      = 0
#         y      = 0
#         width  = 12
#         height = 6
#         properties = {
#           title   = "Endpoint Health"
#           metrics = [
#             ["AWS/SageMaker", "Invocations", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"],
#             ["AWS/SageMaker", "Invocation5XXErrors", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"],
#             ["AWS/SageMaker", "Invocation4XXErrors", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"]
#           ]
#           period = 300
#           stat   = "Sum"
#           region = "us-east-1"
#         }
#       },
#       {
#         type   = "metric"
#         x      = 12
#         y      = 0
#         width  = 12
#         height = 6
#         properties = {
#           title   = "Latency (ms)"
#           metrics = [
#             ["AWS/SageMaker", "ModelLatency", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion", { stat = "p50" }],
#             ["AWS/SageMaker", "ModelLatency", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion", { stat = "p99" }]
#           ]
#           period = 60
#           region = "us-east-1"
#         }
#       },
#       {
#         type   = "metric"
#         x      = 0
#         y      = 6
#         width  = 12
#         height = 6
#         properties = {
#           title   = "Instance Utilization"
#           metrics = [
#             ["/aws/sagemaker/Endpoints", "CPUUtilization", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"],
#             ["/aws/sagemaker/Endpoints", "MemoryUtilization", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"]
#           ]
#           period = 300
#           stat   = "Average"
#           region = "us-east-1"
#         }
#       }
#     ]
#   })
# }
#
# # ─── Outputs ─────────────────────────────────────────────────
# output "alerts_topic_arn" {
#   value = aws_sns_topic.alerts.arn
# }
#
# output "retrain_topic_arn" {
#   value = aws_sns_topic.retrain.arn
# }
#
# output "dashboard_name" {
#   value = aws_cloudwatch_dashboard.mlops.dashboard_name
# }
# ═══════════════════════════════════════════════════════════════
# Monitoring Module
#
# THIS IS WHERE MLOPS BECOMES REAL.
# Without monitoring, you just have a deployed model.
# With monitoring, you have a system that heals itself.
#
# WHAT WE MONITOR:
#   1. Endpoint health   → 5xx errors, latency
#   2. Model quality     → prediction distribution shifts
#   3. Data drift        → input feature distribution changes
#   4. Infrastructure    → CPU, memory, invocation count
#
# ALERT CHAIN:
#   CloudWatch Alarm → SNS Topic → Email / PagerDuty / Lambda (retrain)
# ═══════════════════════════════════════════════════════════════

variable "project_name" { type = string }
variable "environment" { type = string }
variable "name_prefix" { type = string }
variable "sagemaker_endpoint" { type = string }
variable "alert_email" { type = string }
variable "enable_monitoring" { type = bool }
variable "monitoring_bucket" { type = string }
variable "sagemaker_role_arn" { type = string }

# NEW: Lambda ARN for the retrain trigger (wires SNS → Lambda)
variable "retrain_lambda_arn" {
  description = "ARN of the retrain trigger Lambda function"
  type        = string
  default     = ""
}

# ─── SNS Topic (Alert Fan-Out) ──────────────────────────────
# All alarms publish here. SNS fans out to email, Slack, PagerDuty.
resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Separate topic for retrain triggers
resource "aws_sns_topic" "retrain" {
  name = "${var.name_prefix}-retrain-trigger"
}

# ─── ALARM 1: High Error Rate (P1 - Wake up) ────────────────
resource "aws_cloudwatch_metric_alarm" "endpoint_5xx" {
  alarm_name          = "${var.name_prefix}-endpoint-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Invocation5XXErrors"
  namespace           = "AWS/SageMaker"
  period              = 300  # 5 min windows
  statistic           = "Sum"
  threshold           = 10   # More than 10 errors in 5 min = alarm

  dimensions = {
    EndpointName = var.sagemaker_endpoint
    VariantName  = "champion"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  alarm_description = "CRITICAL: SageMaker endpoint returning 5xx errors. Check container logs."
  treat_missing_data = "notBreaching"
}

# ─── ALARM 2: High Latency (P2 - Investigate) ───────────────
resource "aws_cloudwatch_metric_alarm" "endpoint_latency" {
  alarm_name          = "${var.name_prefix}-endpoint-latency-p99"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ModelLatency"
  namespace           = "AWS/SageMaker"
  period              = 300
  extended_statistic  = "p99"
  threshold           = 100000  # 100ms in microseconds

  dimensions = {
    EndpointName = var.sagemaker_endpoint
    VariantName  = "champion"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  alarm_description = "WARNING: p99 latency exceeds 100ms. Check for instance saturation or model bloat."
  treat_missing_data = "notBreaching"
}

# ─── ALARM 3: No Invocations (P2 - System down?) ────────────
resource "aws_cloudwatch_metric_alarm" "no_invocations" {
  alarm_name          = "${var.name_prefix}-no-invocations"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Invocations"
  namespace           = "AWS/SageMaker"
  period              = 300
  statistic           = "Sum"
  threshold           = 1  # Zero invocations for 15 min = alarm

  dimensions = {
    EndpointName = var.sagemaker_endpoint
    VariantName  = "champion"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  alarm_description = "WARNING: No invocations for 15 min. Check API Gateway and upstream services."
  treat_missing_data = "breaching"
}

# ─── ALARM 4: High CPU (triggers auto-scaling awareness) ────
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.name_prefix}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "/aws/sagemaker/Endpoints"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    EndpointName = var.sagemaker_endpoint
    VariantName  = "champion"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  alarm_description = "WARNING: CPU > 80% sustained. Auto-scaling should handle this; verify scaling policy is active."
  treat_missing_data = "notBreaching"
}

# ─── CloudWatch Dashboard ───────────────────────────────────
resource "aws_cloudwatch_dashboard" "mlops" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Endpoint Health"
          metrics = [
            ["AWS/SageMaker", "Invocations", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"],
            ["AWS/SageMaker", "Invocation5XXErrors", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"],
            ["AWS/SageMaker", "Invocation4XXErrors", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"]
          ]
          period = 300
          stat   = "Sum"
          region = "us-east-1"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Latency (ms)"
          metrics = [
            ["AWS/SageMaker", "ModelLatency", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion", { stat = "p50" }],
            ["AWS/SageMaker", "ModelLatency", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion", { stat = "p99" }]
          ]
          period = 60
          region = "us-east-1"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Instance Utilization"
          metrics = [
            ["/aws/sagemaker/Endpoints", "CPUUtilization", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"],
            ["/aws/sagemaker/Endpoints", "MemoryUtilization", "EndpointName", var.sagemaker_endpoint, "VariantName", "champion"]
          ]
          period = 300
          stat   = "Average"
          region = "us-east-1"
        }
      }
    ]
  })
}

# ─── SNS → Lambda Retrain Wiring ─────────────────────────────
# This is the connection that was missing: when the retrain SNS topic
# receives a message, it invokes the retrain Lambda automatically.
# Without these two resources, SNS publishes into the void.

resource "aws_sns_topic_subscription" "retrain_lambda" {
  count     = var.retrain_lambda_arn != "" ? 1 : 0
  topic_arn = aws_sns_topic.retrain.arn
  protocol  = "lambda"
  endpoint  = var.retrain_lambda_arn
}

resource "aws_lambda_permission" "sns_retrain" {
  count         = var.retrain_lambda_arn != "" ? 1 : 0
  statement_id  = "AllowSNSRetrain"
  action        = "lambda:InvokeFunction"
  function_name = var.retrain_lambda_arn
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.retrain.arn
}

# ─── Outputs ─────────────────────────────────────────────────
output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "retrain_topic_arn" {
  value = aws_sns_topic.retrain.arn
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.mlops.dashboard_name
}
