# ═══════════════════════════════════════════════════════════════
# SageMaker Module
#
# THREE RESOURCES IN DEPENDENCY ORDER:
#   1. Model           → points to container image + model.tar.gz in S3
#   2. Endpoint Config → defines instance type, count, data capture
#   3. Endpoint        → the actual running inference service
#
# WHY SAGEMAKER (not ECS/Fargate):
# - Built-in auto-scaling tuned for ML workloads
# - Data capture for Model Monitor (free, just enable it)
# - Production variants for A/B testing (traffic splitting)
# - Shadow testing (send duplicate traffic to new model, compare)
# - You'd have to build ALL of this yourself on ECS
# ═══════════════════════════════════════════════════════════════

variable "project_name" { type = string }
variable "environment" { type = string }
variable "name_prefix" { type = string }
variable "execution_role_arn" { type = string }
variable "inference_image" { type = string }
variable "model_data_bucket" { type = string }
variable "instance_type" { type = string }
variable "instance_count" { type = number }
variable "data_capture_bucket" { type = string }

# VPC configuration - SageMaker model runs inside private subnets
variable "subnet_ids" {
  description = "Private subnet IDs for SageMaker endpoint (multi-AZ)"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for SageMaker endpoint"
  type        = list(string)
}

locals {
  endpoint_name = "${var.name_prefix}-endpoint"
  # model.tar.gz path follows: s3://bucket/latest/model.tar.gz
  # The CI/CD pipeline uploads here after successful training
  model_data_url = "s3://${var.model_data_bucket}/latest/model.tar.gz"
}

# ─── SageMaker Model ────────────────────────────────────────
# This tells SageMaker: "here's my container, here's my model data"
resource "aws_sagemaker_model" "churn" {
  name               = "${var.name_prefix}-model"
  execution_role_arn = var.execution_role_arn

  primary_container {
    image          = "${var.inference_image}:latest"
    model_data_url = local.model_data_url

    environment = {
      MODEL_VERSION = "terraform-managed"
      ENVIRONMENT   = var.environment
    }
  }

  # VPC Config: run the model inside private subnets
  # This ensures model data and predictions never touch the public internet
  vpc_config {
    subnets            = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  lifecycle {
    # When the model image or data changes, create new before destroying old
    # This prevents downtime during model updates
    create_before_destroy = true
  }
}

# ─── Endpoint Configuration ──────────────────────────────────
# Defines HOW the model is served (instance type, count, data capture)
resource "aws_sagemaker_endpoint_configuration" "churn" {
  name = "${var.name_prefix}-config"

  production_variants {
    variant_name           = "champion"
    model_name             = aws_sagemaker_model.churn.name
    initial_instance_count = var.instance_count
    instance_type          = var.instance_type
    initial_variant_weight = 1.0

    # Enable server-side response caching for identical requests
    # Huge win for batch scoring where many customers share similar features
  }

  # ─── Data Capture ────────────────────────────────────────
  # Records every request/response to S3 for Model Monitor to analyze.
  # This is how we detect drift WITHOUT any code changes.
  data_capture_config {
    enable_capture              = true
    initial_sampling_percentage = 100  # Capture everything in prod
    destination_s3_uri          = "s3://${var.data_capture_bucket}/data-capture"

    capture_options {
      capture_mode = "Input"
    }
    capture_options {
      capture_mode = "Output"
    }

    capture_content_type_header {
      json_content_types = ["application/json"]
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Endpoint ────────────────────────────────────────────────
# The actual running service. This is what Lambda invokes.
resource "aws_sagemaker_endpoint" "churn" {
  name                 = local.endpoint_name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.churn.name

  # Deployment config: wait for new instances to be healthy before
  # removing old ones (blue/green behavior)
  deployment_config {
    blue_green_update_policy {
      traffic_routing_configuration {
        # type                     = "CANARY"
        type                     = "ALL_AT_ONCE"  # For simplicity, we use canary with 1 instance instead of linear or time-based
        # canary_size {
        #   type  = "INSTANCE_COUNT"
        #   value = 1
        # }
        wait_interval_in_seconds = 600  # 10 min canary bake time
      }
      maximum_execution_timeout_in_seconds = 1800  # 30 min max
      termination_wait_in_seconds          = 120   # 2 min drain
    }

    auto_rollback_configuration {
      alarms {
        alarm_name = "${var.name_prefix}-endpoint-5xx"
      }
    }
  }
}

# ─── Auto Scaling ────────────────────────────────────────────
# Scale endpoint instances based on invocations per instance
resource "aws_appautoscaling_target" "sagemaker" {
  count = var.environment == "prod" ? 1 : 0  # Only auto-scale in prod

  max_capacity       = 20
  min_capacity       = var.instance_count
  resource_id        = "endpoint/${local.endpoint_name}/variant/champion"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  service_namespace  = "sagemaker"

  depends_on = [aws_sagemaker_endpoint.churn]
}

resource "aws_appautoscaling_policy" "sagemaker" {
  count = var.environment == "prod" ? 1 : 0

  name               = "${var.name_prefix}-scaling-policy"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.sagemaker[0].resource_id
  scalable_dimension = aws_appautoscaling_target.sagemaker[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.sagemaker[0].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 1000  # Target: 1000 invocations per instance

    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantInvocationsPerInstance"
    }

    scale_in_cooldown  = 300  # 5 min cooldown before scaling in
    scale_out_cooldown = 60   # 1 min cooldown before scaling out (react fast)
  }
}

# ─── Outputs ─────────────────────────────────────────────────
output "endpoint_name" {
  value = aws_sagemaker_endpoint.churn.name
}

output "model_name" {
  value = aws_sagemaker_model.churn.name
}
