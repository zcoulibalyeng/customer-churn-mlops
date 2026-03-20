# ═══════════════════════════════════════════════════════════════
# S3 Module
#
# THREE BUCKETS, THREE CONCERNS:
#   1. Data bucket     → raw CSV, processed features, baseline data
#   2. Model bucket    → model.tar.gz artifacts, versioned
#   3. Monitoring bucket → data capture logs, drift reports
#
# WHY SEPARATE BUCKETS:
# - Different lifecycle policies (data retained 7 years, logs 90 days)
# - Different access patterns (data = large reads, models = small reads)
# - Different compliance (data may contain PII, models don't)
# ═══════════════════════════════════════════════════════════════

variable "project_name" { type = string }
variable "environment" { type = string }
variable "name_prefix" { type = string }

# ─── Data Bucket ─────────────────────────────────────────────
resource "aws_s3_bucket" "data" {
  bucket = "${var.name_prefix}-data"

  # Prevent accidental deletion of training data
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# Block all public access - this is non-negotiable for any bucket
resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── Model Artifacts Bucket ──────────────────────────────────
resource "aws_s3_bucket" "models" {
  bucket        = "${var.name_prefix}-models"
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket = aws_s3_bucket.models.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── Monitoring Bucket ───────────────────────────────────────
resource "aws_s3_bucket" "monitoring" {
  bucket        = "${var.name_prefix}-monitoring"
  force_destroy = true  # Monitoring data is regeneratable
}

resource "aws_s3_bucket_versioning" "monitoring" {
  bucket = aws_s3_bucket.monitoring.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "monitoring" {
  bucket = aws_s3_bucket.monitoring.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "monitoring" {
  bucket = aws_s3_bucket.monitoring.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: auto-delete monitoring data after 90 days to control costs
resource "aws_s3_bucket_lifecycle_configuration" "monitoring" {
  bucket = aws_s3_bucket.monitoring.id

  rule {
    id     = "expire-old-monitoring-data"
    status = "Enabled"

    expiration {
      days = 90
    }

    filter {
      prefix = "data-capture/"
    }
  }
}

# ─── Outputs ─────────────────────────────────────────────────
output "data_bucket_name" {
  value = aws_s3_bucket.data.id
}

output "data_bucket_arn" {
  value = aws_s3_bucket.data.arn
}

output "model_bucket_name" {
  value = aws_s3_bucket.models.id
}

output "model_bucket_arn" {
  value = aws_s3_bucket.models.arn
}

output "monitoring_bucket_name" {
  value = aws_s3_bucket.monitoring.id
}
