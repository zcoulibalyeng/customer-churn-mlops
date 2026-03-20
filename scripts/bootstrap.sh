#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Bootstrap Script - RUN THIS ONCE BEFORE FIRST terraform init
#
# Creates:
#   1. S3 bucket for Terraform state (with versioning + encryption)
#   2. DynamoDB table for state locking (prevents concurrent applies)
#
# WHY MANUAL (not Terraform):
# Terraform can't create its own backend. The bucket must exist
# BEFORE terraform init. This is the one CLI command you run by hand.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

REGION="us-east-1"
#STATE_BUCKET="customer-churn-terraform-state"
STATE_BUCKET="customer-churn-terraform-state-codemon-99"
LOCK_TABLE="terraform-lock"

echo "═══════════════════════════════════════════════════"
echo " MLOps Bootstrap - One-Time Setup"
echo "═══════════════════════════════════════════════════"

# ─── Step 1: Create state bucket ─────────────────────────────
echo ""
echo "[1/3] Creating S3 bucket for Terraform state..."
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    echo "  ✓ Bucket already exists: $STATE_BUCKET"
else
    aws s3api create-bucket \
        --bucket "$STATE_BUCKET" \
        --region "$REGION"
    echo "  ✓ Created bucket: $STATE_BUCKET"
fi

# Enable versioning (recover from bad state files)
aws s3api put-bucket-versioning \
    --bucket "$STATE_BUCKET" \
    --versioning-configuration Status=Enabled
echo "  ✓ Versioning enabled"

# Enable encryption
aws s3api put-bucket-encryption \
    --bucket "$STATE_BUCKET" \
    --server-side-encryption-configuration '{
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]
    }'
echo "  ✓ Encryption enabled (KMS)"

# Block public access
aws s3api put-public-access-block \
    --bucket "$STATE_BUCKET" \
    --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  ✓ Public access blocked"

# ─── Step 2: Create DynamoDB lock table ──────────────────────
echo ""
echo "[2/3] Creating DynamoDB table for state locking..."
if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" 2>/dev/null; then
    echo "  ✓ Table already exists: $LOCK_TABLE"
else
    aws dynamodb create-table \
        --table-name "$LOCK_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$REGION"
    echo "  ✓ Created table: $LOCK_TABLE"

    # Wait for table to become active
    aws dynamodb wait table-exists --table-name "$LOCK_TABLE" --region "$REGION"
    echo "  ✓ Table is active"
fi

# ─── Step 3: Upload initial training data ────────────────────
echo ""
echo "[3/3] Uploading training data..."
if [ -f "data/bank_data.csv" ]; then
    # Create data buckets for dev environment
    for ENV in dev prod; do
        #BUCKET="customer-churn-${ENV}-data"
        BUCKET="customer-churn-${ENV}-data-codemon-99"
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null || true
        aws s3 cp data/bank_data.csv "s3://${BUCKET}/raw/bank_data.csv"
        echo "  ✓ Data uploaded to s3://${BUCKET}/raw/bank_data.csv"
    done
else
    echo "  ⚠ data/bank_data.csv not found. Upload manually later."
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo " Bootstrap COMPLETE"
echo ""
echo " Next steps:"
echo "   1. cd terraform/environments/dev"
echo "   2. terraform init"
echo "   3. terraform plan -var-file=terraform.tfvars"
echo "   4. terraform apply"
echo "═══════════════════════════════════════════════════"
