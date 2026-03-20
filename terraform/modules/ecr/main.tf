# ═══════════════════════════════════════════════════════════════
# ECR Module
#
# TWO REPOS:
#   1. Training   → runs GridSearchCV, outputs model.tar.gz to S3
#   2. Inference   → Flask app, loads model, serves /invocations
#
# WHY ECR (not Docker Hub):
# - Private by default (no accidental public image leaks)
# - scan_on_push catches CVEs before deployment
# - Lifecycle policies auto-delete old untagged images (saves $)
# - No Docker Hub rate limits on pulls from SageMaker
# ═══════════════════════════════════════════════════════════════

variable "project_name" { type = string }
variable "environment" { type = string }
variable "name_prefix" { type = string }

# ─── Training Container Registry ─────────────────────────────
resource "aws_ecr_repository" "training" {
  name = "${var.name_prefix}-training"

  image_scanning_configuration {
    scan_on_push = true  # Catches CVEs on every push
  }

  # image_tag_mutability = "IMMUTABLE"
  image_tag_mutability = "MUTABLE"
  # IMMUTABLE means once you push :v1.2.3, it can never be overwritten.
  # This guarantees reproducibility: the image behind a model version
  # is always the same image.

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# ─── Inference Container Registry ────────────────────────────
resource "aws_ecr_repository" "inference" {
  name = "${var.name_prefix}-inference"

  image_scanning_configuration {
    scan_on_push = true
  }

  # image_tag_mutability = "IMMUTABLE"
  image_tag_mutability = "MUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# ─── Lifecycle Policy ────────────────────────────────────────
# Keep last 20 tagged images, delete untagged after 7 days.
# Without this, ECR costs grow unbounded with every CI/CD push.
resource "aws_ecr_lifecycle_policy" "training" {
  repository = aws_ecr_repository.training.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["v"]
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Remove untagged after 7 days"
        selection = {
          tagStatus = "untagged"
          countType = "sinceImagePushed"
          countUnit = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "inference" {
  repository = aws_ecr_repository.inference.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Remove untagged after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ─── Outputs ─────────────────────────────────────────────────
output "training_repository_url" {
  value = aws_ecr_repository.training.repository_url
}

output "inference_repository_url" {
  value = aws_ecr_repository.inference.repository_url
}
