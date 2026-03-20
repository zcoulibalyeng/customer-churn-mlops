# ═══════════════════════════════════════════════════════════════
# Production Environment
#
# IDENTICAL module structure to dev. The only difference is
# terraform.tfvars (more instances, monitoring ON, etc.)
#
# This is intentional: dev and prod should be structurally identical.
# The only differences should be scale and cost parameters.
# If you need different RESOURCES in prod, you're doing it wrong.
# ═══════════════════════════════════════════════════════════════

# The main.tf is identical to dev - copy it and change nothing.
# In practice, you'd use symlinks or Terragrunt to avoid duplication.
# For clarity in this guide, we keep a full copy.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "customer-churn-terraform-state-codemon-99"
    key            = "prod/terraform.tfstate"
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

variable "project_name" {
  type    = string
  default = "customer-churn"
}
variable "environment" {
  type = string
}
variable "aws_region" {
  type = string
  default = "us-east-1"
}
variable "model_instance_type" {
  type = string
  default = "ml.m5.xlarge"
}
variable "model_instance_count" {
  type = number
  default = 2
}
variable "enable_monitoring" {
  type = bool
  default = true
}
variable "alert_email" {
  type = string
  default = "zcoulibalyeng@gmail.com"
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

module "iam" {
  source = "../../modules/iam"
  project_name = var.project_name
  environment = var.environment
  name_prefix = local.name_prefix
}
module "vpc" {
  source = "../../modules/vpc"
  project_name = var.project_name
  environment = var.environment
  name_prefix = local.name_prefix
  enable_nat_gateway = true
}
module "s3" {
  source = "../../modules/s3"
  project_name = var.project_name
  environment = var.environment
  name_prefix = local.name_prefix
}
module "ecr" {
  source = "../../modules/ecr"
  project_name = var.project_name
  environment = var.environment
  name_prefix = local.name_prefix
}
module "sagemaker" {
  source = "../../modules/sagemaker"
  project_name = var.project_name
  environment = var.environment
  name_prefix = local.name_prefix
  execution_role_arn = module.iam.sagemaker_role_arn
  inference_image = module.ecr.inference_repository_url
  model_data_bucket = module.s3.model_bucket_name
  instance_type = var.model_instance_type
  instance_count = var.model_instance_count
  data_capture_bucket = module.s3.monitoring_bucket_name
  subnet_ids = module.vpc.private_subnet_ids
  security_group_ids = [module.vpc.sagemaker_security_group_id]
}
module "lambda" {
  source = "../../modules/lambda"
  project_name = var.project_name
  environment = var.environment
  name_prefix = local.name_prefix
  sagemaker_endpoint = module.sagemaker.endpoint_name
  lambda_role_arn = module.iam.lambda_role_arn
  subnet_ids = module.vpc.private_subnet_ids
  security_group_ids = [module.vpc.lambda_security_group_id]
}
module "api_gateway" {
  source = "../../modules/api-gateway"
  project_name = var.project_name
  environment = var.environment
  name_prefix = local.name_prefix
  lambda_invoke_arn = module.lambda.invoke_arn
  lambda_function_name = module.lambda.function_name
}
module "monitoring" {
  source = "../../modules/monitoring"
  project_name = var.project_name
  environment = var.environment
  name_prefix = local.name_prefix
  sagemaker_endpoint = module.sagemaker.endpoint_name
  alert_email = var.alert_email
  enable_monitoring = var.enable_monitoring
  monitoring_bucket = module.s3.monitoring_bucket_name
  sagemaker_role_arn = module.iam.sagemaker_role_arn
}

output "api_endpoint" {
  value = module.api_gateway.api_url
}
output "sagemaker_endpoint" {
  value = module.sagemaker.endpoint_name
}
