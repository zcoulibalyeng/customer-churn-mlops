# ═══════════════════════════════════════════════════════════════
# VPC Module - Network Isolation
#
# WHY THIS IS NON-NEGOTIABLE:
#
# Without a VPC, your SageMaker endpoint sits on AWS's shared
# network. That means:
#   - Model data traverses the public internet to reach S3
#   - Anyone with the endpoint URL can attempt to hit it
#   - No network-level audit trail
#   - Fails PCI-DSS, SOC 2, and every Amazon security review
#
# WITH a VPC:
#   - SageMaker runs in private subnets (no public IP, no internet)
#   - S3/ECR/CloudWatch access via VPC Endpoints (traffic never
#     leaves AWS's backbone network)
#   - Security groups act as instance-level firewalls
#   - VPC Flow Logs capture every packet for forensics
#   - Lambda runs inside the VPC so it can reach SageMaker privately
#
# ARCHITECTURE:
#   ┌─────────────────── VPC (10.0.0.0/16) ───────────────────┐
#   │                                                          │
#   │  ┌─── Public Subnet (AZ-a) ──┐  ┌── Public Subnet (AZ-b) ──┐
#   │  │  NAT Gateway              │  │  NAT Gateway              │
#   │  └────────────────────────────┘  └───────────────────────────┘
#   │                                                          │
#   │  ┌── Private Subnet (AZ-a) ──┐  ┌── Private Subnet (AZ-b) ──┐
#   │  │  SageMaker Endpoint       │  │  SageMaker Endpoint       │
#   │  │  Lambda Functions         │  │  Lambda Functions         │
#   │  └────────────────────────────┘  └───────────────────────────┘
#   │                                                          │
#   │  VPC Endpoints: S3, ECR, SageMaker, CloudWatch, STS     │
#   └──────────────────────────────────────────────────────────┘
#
# WHY 2 AZs:
#   SageMaker needs at least 2 subnets in different AZs for
#   high availability. If AZ-a goes down, AZ-b keeps serving.
#
# WHY NAT GATEWAY:
#   Private subnets can't reach the internet directly.
#   NAT Gateway lets them pull Docker images from ECR and
#   download pip packages during training. But inbound traffic
#   from the internet is still blocked.
#
# WHY VPC ENDPOINTS (not NAT for everything):
#   NAT Gateway costs $0.045/GB of data processed.
#   VPC Endpoints are free for S3 (Gateway type) and $0.01/hr
#   for interface endpoints. Since SageMaker reads multi-GB
#   model artifacts from S3 on every deploy, the S3 VPC Endpoint
#   alone saves hundreds of dollars per month AND is faster
#   (traffic stays on AWS's internal network).
# ═══════════════════════════════════════════════════════════════

variable "project_name" { type = string }
variable "environment" { type = string }
variable "name_prefix" { type = string }

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
  # /16 = 65,536 IPs. Overkill for this project, but gives room
  # to add more subnets later without re-IPing.
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway (disable in dev to save $32/month per AZ)"
  type        = bool
  default     = true
}

# Look up available AZs in the region
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# ─── VPC ─────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true   # Required for VPC Endpoints
  enable_dns_hostnames = true   # Required for SageMaker

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# ─── Public Subnets (for NAT Gateways only) ─────────────────
# Nothing else runs here. These exist solely to give NAT Gateways
# a path to the internet via the Internet Gateway.
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  # Result: 10.0.0.0/24, 10.0.1.0/24 (256 IPs each)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false  # Even public subnets don't auto-assign public IPs

  tags = {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

# ─── Private Subnets (where everything runs) ────────────────
# SageMaker endpoints, Lambda functions, and any future compute
# all run here. No public IP, no direct internet access.
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  # Result: 10.0.10.0/24, 10.0.11.0/24
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# ─── Internet Gateway ───────────────────────────────────────
# Provides internet access for the PUBLIC subnets only.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# ─── NAT Gateways ───────────────────────────────────────────
# One per AZ for high availability. Gives private subnets
# outbound-only internet access (for ECR pulls, pip installs).
#
# COST NOTE: Each NAT Gateway is ~$32/month + $0.045/GB.
# In dev, set enable_nat_gateway=false and rely on VPC Endpoints
# for S3/ECR access (training jobs won't need pip install if
# the container is pre-built).
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 2 : 0
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip-${count.index}"
  }
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 2 : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${local.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.main]
}

# ─── Route Tables ────────────────────────────────────────────
# Public subnets → route to Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private subnets → route to NAT Gateway (if enabled)
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-private-rt-${count.index}" }
}

resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? 2 : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ─── Security Groups ────────────────────────────────────────

# SageMaker Endpoint security group
# Only allows inbound from Lambda security group on port 443
resource "aws_security_group" "sagemaker" {
  name_prefix = "${var.name_prefix}-sagemaker-"
  vpc_id      = aws_vpc.main.id
  description = "SageMaker endpoint - only accepts traffic from Lambda"

  # Inbound: HTTPS from Lambda only
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
    description     = "HTTPS from Lambda preprocessor"
  }

  # Outbound: S3 and CloudWatch via VPC endpoints
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS to VPC endpoints and AWS services"
  }

  tags = { Name = "${var.name_prefix}-sagemaker-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# Lambda security group
# Allows outbound to SageMaker and VPC endpoints only
resource "aws_security_group" "lambda" {
  name_prefix = "${var.name_prefix}-lambda-"
  vpc_id      = aws_vpc.main.id
  description = "Lambda functions - outbound to SageMaker and AWS services"

  # No inbound rules - Lambda is invoked by API Gateway, not by
  # network connections. API Gateway invokes Lambda via the
  # Lambda service, not over the VPC network.

  # Outbound: to SageMaker and VPC endpoints
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS to SageMaker endpoint and AWS services"
  }

  tags = { Name = "${var.name_prefix}-lambda-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# VPC Endpoints security group
# Allows inbound HTTPS from any resource in the VPC
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.name_prefix}-vpce-"
  vpc_id      = aws_vpc.main.id
  description = "VPC Endpoints - accepts HTTPS from VPC resources"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from any VPC resource"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS outbound"
  }

  tags = { Name = "${var.name_prefix}-vpce-sg" }
}

# ─── VPC Endpoints ───────────────────────────────────────────
# These allow private subnets to reach AWS services WITHOUT
# going through NAT Gateway (faster + cheaper).

# S3 Gateway Endpoint (FREE - no hourly charge, no data charge)
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = aws_route_table.private[*].id

  tags = { Name = "${var.name_prefix}-vpce-s3" }
}

# ECR API (needed to authenticate docker pulls)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.name_prefix}-vpce-ecr-api" }
}

# ECR Docker (needed to pull container layers)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.name_prefix}-vpce-ecr-dkr" }
}

# SageMaker API (needed for invoke_endpoint calls from Lambda)
resource "aws_vpc_endpoint" "sagemaker_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sagemaker.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.name_prefix}-vpce-sagemaker-api" }
}

# SageMaker Runtime (needed for real-time inference)
resource "aws_vpc_endpoint" "sagemaker_runtime" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sagemaker.runtime"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.name_prefix}-vpce-sagemaker-runtime" }
}

# CloudWatch Logs (so containers can write logs without NAT)
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.name_prefix}-vpce-logs" }
}

# CloudWatch Monitoring (so endpoints can push metrics)
resource "aws_vpc_endpoint" "cloudwatch_monitoring" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.monitoring"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.name_prefix}-vpce-monitoring" }
}

# STS (needed for IAM role assumption inside VPC)
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.name_prefix}-vpce-sts" }
}

# ─── VPC Flow Logs ───────────────────────────────────────────
# Captures ALL network traffic metadata for security auditing.
# Required by PCI-DSS and SOC 2.
resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.flow_log.arn
  log_destination = aws_cloudwatch_log_group.flow_log.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-flow-log" }
}

resource "aws_cloudwatch_log_group" "flow_log" {
  name              = "/aws/vpc/flowlogs/${var.name_prefix}"
  retention_in_days = var.environment == "prod" ? 365 : 14
}

resource "aws_iam_role" "flow_log" {
  name = "${var.name_prefix}-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "flow_log" {
  name = "${var.name_prefix}-flow-log-policy"
  role = aws_iam_role.flow_log.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

# ─── Outputs ─────────────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID for other modules to reference"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs for SageMaker and Lambda"
  value       = aws_subnet.private[*].id
}

output "sagemaker_security_group_id" {
  description = "Security group for SageMaker endpoints"
  value       = aws_security_group.sagemaker.id
}

output "lambda_security_group_id" {
  description = "Security group for Lambda functions"
  value       = aws_security_group.lambda.id
}
