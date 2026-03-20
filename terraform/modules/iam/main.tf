# ═══════════════════════════════════════════════════════════════
# IAM Module
#
# WHY THIS EXISTS:
# Every AWS service needs an IAM role. We define them all here
# so security can audit one file, not hunt through 6 modules.
#
# PRINCIPLE: Least privilege. Each role gets ONLY what it needs.
# The SageMaker role can read S3 and write to ECR.
# The Lambda role can invoke SageMaker and write CloudWatch logs.
# Neither can do anything else.
# ═══════════════════════════════════════════════════════════════

variable "project_name" { type = string }
variable "environment" { type = string }
variable "name_prefix" { type = string }

# ─── SageMaker Execution Role ────────────────────────────────
# Used by: Training jobs, Processing jobs, Endpoints, Model Monitor
resource "aws_iam_role" "sagemaker" {
  name = "${var.name_prefix}-sagemaker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "sagemaker.amazonaws.com"
      }
    },
    {
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:zcoulibalyeng/customer-churn-mlops:*"
        }
      }
    }
  ]
 })
}

# SageMaker needs: S3 (read data, write models), ECR (pull containers),
# CloudWatch (write logs/metrics), SageMaker API (create endpoints)
resource "aws_iam_role_policy" "sagemaker_policy" {
  name = "${var.name_prefix}-sagemaker-policy"
  role = aws_iam_role.sagemaker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-*",
          "arn:aws:s3:::${var.name_prefix}-*/*"
        ]
      },
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Sid    = "SageMakerFullAccess"
        Effect = "Allow"
        Action = [
          "sagemaker:*"
        ]
        Resource = "arn:aws:sagemaker:*:*:*/${var.name_prefix}-*"
      },
      {
        Sid    = "VPCNetworkAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:CreateNetworkInterfacePermission",
          "ec2:DeleteNetworkInterface",
          "ec2:DeleteNetworkInterfacePermission",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeVpcs",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

# ─── Lambda Execution Role ───────────────────────────────────
# Used by: Preprocessing Lambda, Retrain trigger Lambda
resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.name_prefix}-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeSageMaker"
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint"
        ]
        Resource = "arn:aws:sagemaker:*:*:endpoint/${var.name_prefix}-*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "StartRetraining"
        Effect = "Allow"
        Action = [
          "sagemaker:StartPipelineExecution"
        ]
        Resource = "arn:aws:sagemaker:*:*:pipeline/${var.name_prefix}-*"
      },
      {
        # WHY THIS IS NEEDED:
        # When Lambda runs inside a VPC, it creates an Elastic Network
        # Interface (ENI) in the subnet. Without these permissions,
        # the Lambda invoke fails with "The provided execution role
        # does not have permissions to call CreateNetworkInterface".
        Sid    = "VPCAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }
    ]
  })
}
# ─── API Gateway CloudWatch Logging ──────────────────────────
resource "aws_iam_role" "api_gateway_logging" {
  name = "${var.name_prefix}-apigw-logging-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_gateway_logging" {
  role       = aws_iam_role.api_gateway_logging.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_logging.arn
}


# GitHub OIDC Provider for GitHub Actions to authenticate and push images to ECR.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["1b5113038660a9f600f1352e85a6663f70557b7a"]
}

# This allows the role to push images to ECR
resource "aws_iam_role_policy_attachment" "sagemaker_ecr" {
  role       = aws_iam_role.sagemaker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# This allows Terraform in GitHub Actions to manage its own state file
resource "aws_iam_role_policy" "terraform_state_access" {
  name = "${var.name_prefix}-terraform-state-policy"
  role = aws_iam_role.sagemaker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Permission to list the bucket
        Action = ["s3:ListBucket"]
        Effect = "Allow"
        Resource = ["arn:aws:s3:::customer-churn-terraform-state-codemon-99"]
      },
      {
        # Permission to read/write the state files inside
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Effect = "Allow"
        Resource = ["arn:aws:s3:::customer-churn-terraform-state-codemon-99/*"]
      }
    ]
  })
}

# This allows Terraform in GitHub to "Lock" the state so nobody else interferes
resource "aws_iam_role_policy" "terraform_lock_access" {
  name = "${var.name_prefix}-terraform-lock-policy"
  role = aws_iam_role.sagemaker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:dynamodb:us-east-1:011839104711:table/terraform-lock"
      }
    ]
  })
}

# This gives the GitHub Action Role the power to manage ALL resources in the plan
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.sagemaker.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ─── Outputs ─────────────────────────────────────────────────
output "sagemaker_role_arn" {
  value = aws_iam_role.sagemaker.arn
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
}
