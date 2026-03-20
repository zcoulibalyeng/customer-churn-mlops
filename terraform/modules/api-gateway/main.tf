# ═══════════════════════════════════════════════════════════════
# API Gateway Module
#
# WHY API GATEWAY (not direct SageMaker invoke):
# 1. Public HTTPS endpoint with TLS termination
# 2. Request throttling (protect SageMaker from traffic spikes)
# 3. API keys for client authentication
# 4. Request/response transformation
# 5. Usage plans with quotas per client
# 6. CloudWatch access logs for debugging
# ═══════════════════════════════════════════════════════════════

variable "project_name" { type = string }
variable "environment" { type = string }
variable "name_prefix" { type = string }
variable "lambda_invoke_arn" { type = string }
variable "lambda_function_name" { type = string }

# ─── REST API ────────────────────────────────────────────────
resource "aws_api_gateway_rest_api" "churn" {
  name        = "${var.name_prefix}-api"
  description = "Customer Churn Prediction API (${var.environment})"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# ─── /predict resource ───────────────────────────────────────
resource "aws_api_gateway_resource" "predict" {
  rest_api_id = aws_api_gateway_rest_api.churn.id
  parent_id   = aws_api_gateway_rest_api.churn.root_resource_id
  path_part   = "predict"
}

resource "aws_api_gateway_method" "predict_post" {
  rest_api_id   = aws_api_gateway_rest_api.churn.id
  resource_id   = aws_api_gateway_resource.predict.id
  http_method   = "POST"
  authorization = "NONE"  # Add API key auth in prod
}

resource "aws_api_gateway_integration" "predict_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.churn.id
  resource_id             = aws_api_gateway_resource.predict.id
  http_method             = aws_api_gateway_method.predict_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arn
}

# ─── /health resource ───────────────────────────────────────
resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.churn.id
  parent_id   = aws_api_gateway_rest_api.churn.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_method" "health_get" {
  rest_api_id   = aws_api_gateway_rest_api.churn.id
  resource_id   = aws_api_gateway_resource.health.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "health_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.churn.id
  resource_id             = aws_api_gateway_resource.health.id
  http_method             = aws_api_gateway_method.health_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arn
}

# ─── Deployment ──────────────────────────────────────────────
resource "aws_api_gateway_deployment" "churn" {
  rest_api_id = aws_api_gateway_rest_api.churn.id

  depends_on = [
    aws_api_gateway_integration.predict_lambda,
    aws_api_gateway_integration.health_lambda
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# resource "aws_api_gateway_stage" "churn" {
#   deployment_id = aws_api_gateway_deployment.churn.id
#   rest_api_id   = aws_api_gateway_rest_api.churn.id
#   stage_name    = var.environment
#
#   # Throttle to protect downstream SageMaker endpoint
#   # These values should match your auto-scaling capacity
#   method_settings {
#     method_path = "*/*"
#     metrics_enabled = true
#     logging_level   = "INFO"
#
#     throttling_rate_limit  = 5000  # requests per second
#     throttling_burst_limit = 10000
#   }
# }

resource "aws_api_gateway_stage" "churn" {
  deployment_id = aws_api_gateway_deployment.churn.id
  rest_api_id   = aws_api_gateway_rest_api.churn.id
  stage_name    = var.environment
}

# ─── Stage Settings (Extracted) ──────────────────────────────
resource "aws_api_gateway_method_settings" "churn_settings" {
  rest_api_id = aws_api_gateway_rest_api.churn.id
  stage_name  = aws_api_gateway_stage.churn.stage_name
  method_path = "*/*" # Applies to all routes in the stage

  # Throttle to protect downstream SageMaker endpoint
  # These values should match your auto-scaling capacity
  settings {
    metrics_enabled        = true
    logging_level          = "INFO"
    throttling_rate_limit  = 5000  # requests per second
    throttling_burst_limit = 10000
  }
}

# ─── Lambda Permission ──────────────────────────────────────
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.churn.execution_arn}/*"
}

# ─── Outputs ─────────────────────────────────────────────────
output "api_url" {
  value = "${aws_api_gateway_stage.churn.invoke_url}/predict"
}

output "api_id" {
  value = aws_api_gateway_rest_api.churn.id
}
