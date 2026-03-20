# ═══════════════════════════════════════════════════════════════
# Root Terraform Configuration
# This is the entry point. It calls each module in dependency order.
#
# WHY MODULES?
# Each AWS service gets its own module so you can:
#   1. Reuse it across dev/staging/prod with different vars
#   2. Destroy one layer without touching others
#   3. Review changes scoped to one concern
# ═══════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ─── Remote State ──────────────────────────────────────────
  # CRITICAL: Never store .tfstate locally in a team project.
  # S3 backend gives you: locking (DynamoDB), versioning, encryption.
  # You create this bucket ONCE manually before first `terraform init`.
  backend "s3" {
    bucket         = "customer-churn-terraform-state-codemon-99"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Team        = "ml-engineering"
    }
  }
}

# ─── Variables ───────────────────────────────────────────────
variable "project_name" {
  description = "Project identifier used in all resource names"
  type        = string
  default     = "customer-churn"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "model_instance_type" {
  description = "SageMaker endpoint instance type"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "model_instance_count" {
  description = "Number of inference instances (min 2 for HA in prod)"
  type        = number
  default     = 1
}

variable "enable_monitoring" {
  description = "Enable Model Monitor (disable in dev to save cost)"
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email for CloudWatch alarm notifications"
  type        = string
  default     = "zcoulibalyeng@gmail.com"
}

# ─── Local Values ────────────────────────────────────────────
locals {
  # Every resource name follows: {project}-{component}-{environment}
  # This prevents name collisions across environments
  name_prefix = "${var.project_name}-${var.environment}"
}

# ═══════════════════════════════════════════════════════════════
# MODULE 1: IAM (must come first - everything else needs roles)
# ═══════════════════════════════════════════════════════════════
module "iam" {
  source = "../../modules/iam"

  project_name = var.project_name
  environment  = var.environment
  name_prefix  = local.name_prefix
}

# ═══════════════════════════════════════════════════════════════
# MODULE 2: VPC (must come before SageMaker and Lambda)
# Network isolation: private subnets, security groups, VPC endpoints
# ═══════════════════════════════════════════════════════════════
module "vpc" {
  source = "../../modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  name_prefix        = local.name_prefix
  enable_nat_gateway = var.environment == "prod"
  # Dev: no NAT Gateway ($0/month) - VPC endpoints handle S3/ECR
  # Prod: NAT Gateway ($64/month for 2 AZs) - full outbound access
}

# ═══════════════════════════════════════════════════════════════
# MODULE 3: S3 (data lake, model artifacts, monitoring output)
# ═══════════════════════════════════════════════════════════════
module "s3" {
  source = "../../modules/s3"

  project_name = var.project_name
  environment  = var.environment
  name_prefix  = local.name_prefix
}

# ═══════════════════════════════════════════════════════════════
# MODULE 4: ECR (container registries for training + inference)
# ═══════════════════════════════════════════════════════════════
module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
  environment  = var.environment
  name_prefix  = local.name_prefix
}

# ═══════════════════════════════════════════════════════════════
# MODULE 5: SageMaker (model, endpoint config, endpoint)
# ═══════════════════════════════════════════════════════════════
module "sagemaker" {
  source = "../../modules/sagemaker"

  project_name       = var.project_name
  environment        = var.environment
  name_prefix        = local.name_prefix
  execution_role_arn = module.iam.sagemaker_role_arn
  inference_image    = module.ecr.inference_repository_url
  model_data_bucket  = module.s3.model_bucket_name
  instance_type      = var.model_instance_type
  instance_count     = var.model_instance_count
  data_capture_bucket = module.s3.monitoring_bucket_name
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [module.vpc.sagemaker_security_group_id]
}

# ═══════════════════════════════════════════════════════════════
# MODULE 6: API Gateway + Lambda (REST API in front of SageMaker)
# ═══════════════════════════════════════════════════════════════
module "api_gateway" {
  source = "../../modules/api-gateway"

  project_name       = var.project_name
  environment        = var.environment
  name_prefix        = local.name_prefix
  lambda_invoke_arn  = module.lambda.invoke_arn
  lambda_function_name = module.lambda.function_name
}

module "lambda" {
  source = "../../modules/lambda"

  project_name       = var.project_name
  environment        = var.environment
  name_prefix        = local.name_prefix
  sagemaker_endpoint = module.sagemaker.endpoint_name
  lambda_role_arn    = module.iam.lambda_role_arn
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [module.vpc.lambda_security_group_id]
}

# ═══════════════════════════════════════════════════════════════
# MODULE 6: Monitoring (CloudWatch alarms, SNS, Model Monitor)
# ═══════════════════════════════════════════════════════════════
module "monitoring" {
  source = "../../modules/monitoring"

  project_name        = var.project_name
  environment         = var.environment
  name_prefix         = local.name_prefix
  sagemaker_endpoint  = module.sagemaker.endpoint_name
  alert_email         = var.alert_email
  enable_monitoring   = var.enable_monitoring
  monitoring_bucket   = module.s3.monitoring_bucket_name
  sagemaker_role_arn  = module.iam.sagemaker_role_arn
}

# ─── Outputs ─────────────────────────────────────────────────
output "api_endpoint" {
  description = "Public URL for predictions"
  value       = module.api_gateway.api_url
}

output "sagemaker_endpoint" {
  description = "SageMaker endpoint name"
  value       = module.sagemaker.endpoint_name
}

output "model_bucket" {
  description = "S3 bucket for model artifacts"
  value       = module.s3.model_bucket_name
}

output "data_bucket" {
  description = "S3 bucket for training data"
  value       = module.s3.data_bucket_name
}

output "training_ecr" {
  description = "ECR repository for training container"
  value       = module.ecr.training_repository_url
}

output "inference_ecr" {
  description = "ECR repository for inference container"
  value       = module.ecr.inference_repository_url
}
