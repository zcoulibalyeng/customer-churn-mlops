# ═══════════════════════════════════════════════════════════════
# Lambda Module
#
# WHY LAMBDA BETWEEN API GATEWAY AND SAGEMAKER:
# 1. Input validation (reject bad payloads before wasting endpoint compute)
# 2. Feature enrichment (lookup cached target-encoded values)
# 3. Response formatting (add metadata, sanitize output)
# 4. Rate limiting / throttling at the application layer
# 5. Retrain trigger (separate Lambda invoked by SNS on drift alarm)
#
# The Lambda is packaged from src/serving/lambda_handler.py
# and deployed as a zip in S3 (GitHub Actions uploads it).
# ═══════════════════════════════════════════════════════════════

variable "project_name" { type = string }
variable "environment" { type = string }
variable "name_prefix" { type = string }
variable "sagemaker_endpoint" { type = string }
variable "lambda_role_arn" { type = string }

# VPC configuration - Lambda runs inside private subnets to reach SageMaker
variable "subnet_ids" {
  description = "Private subnet IDs for Lambda"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for Lambda"
  type        = list(string)
}

# ─── Prediction Lambda ───────────────────────────────────────
resource "aws_lambda_function" "predict" {
  function_name = "${var.name_prefix}-predict"
  role          = var.lambda_role_arn
  handler       = "lambda_handler.handler"
  runtime       = "python3.10"
  timeout       = 30
  memory_size   = 256

  # The zip is uploaded by CI/CD to S3
  s3_bucket = "${var.name_prefix}-models"
  s3_key    = "lambda/predict.zip"

  environment {
    variables = {
      SAGEMAKER_ENDPOINT = var.sagemaker_endpoint
      ENVIRONMENT        = var.environment
    }
  }

  # VPC Config: Lambda runs in private subnets so it can reach
  # SageMaker via the VPC endpoint (private network, not internet)
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  # Reserved concurrency prevents a traffic spike from affecting
  # other Lambdas in the account
  # reserved_concurrent_executions = var.environment == "prod" ? 500 : 10

  tracing_config {
    mode = "Active"  # Enable X-Ray tracing for every invocation
  }
}

# ─── Retrain Trigger Lambda ──────────────────────────────────
# This Lambda is invoked by SNS when Model Monitor detects drift.
# It starts the SageMaker Pipeline to retrain the model.
resource "aws_lambda_function" "retrain_trigger" {
  function_name = "${var.name_prefix}-retrain-trigger"
  role          = var.lambda_role_arn
  handler       = "retrain_trigger.handler"
  runtime       = "python3.10"
  timeout       = 60
  memory_size   = 128

  s3_bucket = "${var.name_prefix}-models"
  s3_key    = "lambda/retrain_trigger.zip"

  environment {
    variables = {
      PIPELINE_NAME = "${var.name_prefix}-training-pipeline"
      DATA_BUCKET   = "${var.name_prefix}-data"
      ENVIRONMENT   = var.environment
    }
  }

  # reserved_concurrent_executions = 1  # Only 1 retrain at a time
}

# ─── CloudWatch Log Groups ──────────────────────────────────
# Explicit log groups with retention. Without this, Lambda creates
# log groups with INFINITE retention (costs grow forever).
resource "aws_cloudwatch_log_group" "predict" {
  name              = "/aws/lambda/${aws_lambda_function.predict.function_name}"
  retention_in_days = var.environment == "prod" ? 90 : 14
}

resource "aws_cloudwatch_log_group" "retrain" {
  name              = "/aws/lambda/${aws_lambda_function.retrain_trigger.function_name}"
  retention_in_days = var.environment == "prod" ? 90 : 14
}

# ─── Outputs ─────────────────────────────────────────────────
output "invoke_arn" {
  value = aws_lambda_function.predict.invoke_arn
}

output "function_name" {
  value = aws_lambda_function.predict.function_name
}

output "retrain_function_arn" {
  value = aws_lambda_function.retrain_trigger.arn
}
