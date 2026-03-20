#!/usr/bin/env bash
set -e

# AWS & Environment Variables
ACCOUNT_ID="011839104711"
REGION="us-east-1"
ENV="dev"

PREFIX="customer-churn-${ENV}"
MODELS_BUCKET="${PREFIX}-models"
INFERENCE_REPO="${PREFIX}-inference"
TRAINING_REPO="${PREFIX}-training"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "═══════════════════════════════════════════════════"
echo " Build & Push Artifacts for ${ENV} Environment"
echo "═══════════════════════════════════════════════════"

# ─── 1. Package and Upload Lambdas ────────────────────────
echo ""
echo "[1/3] Packaging Lambda Functions..."
mkdir -p build/lambda

echo "  -> Zipping predict lambda..."
zip -j build/lambda/predict.zip src/serving/lambda_handler.py

echo "  -> Zipping retrain trigger lambda..."
zip -j build/lambda/retrain_trigger.zip src/serving/retrain_trigger.py

echo "  -> Uploading to S3..."
aws s3 cp build/lambda/predict.zip s3://${MODELS_BUCKET}/lambda/predict.zip
aws s3 cp build/lambda/retrain_trigger.zip s3://${MODELS_BUCKET}/lambda/retrain_trigger.zip
echo "  ✓ Lambda upload complete!"

# ─── 2. Authenticate Docker with AWS ECR ──────────────────
echo ""
echo "[2/3] Authenticating Docker with ECR..."
aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}

# ─── 3. Build and Push Docker Images ──────────────────────
echo ""
echo "[3/3] Building and Pushing Docker Images..."

# --- Inference Image ---
echo "  -> Building Inference Image..."
docker build --platform linux/amd64 --provenance=false -t ${INFERENCE_REPO}:latest -f containers/inference/Dockerfile .
docker tag ${INFERENCE_REPO}:latest ${ECR_REGISTRY}/${INFERENCE_REPO}:latest
docker push ${ECR_REGISTRY}/${INFERENCE_REPO}:latest
echo "  ✓ Inference image pushed!"

# --- Training Image ---
echo "  -> Building Training Image..."
docker build --platform linux/amd64 --provenance=false -t ${TRAINING_REPO}:latest -f containers/training/Dockerfile .
docker tag ${TRAINING_REPO}:latest ${ECR_REGISTRY}/${TRAINING_REPO}:latest
docker push ${ECR_REGISTRY}/${TRAINING_REPO}:latest
echo "  ✓ Training image pushed!"

echo ""
echo "═══════════════════════════════════════════════════"
echo " Success! All dependencies are in the cloud."
echo " You can now run 'terraform apply' safely."
echo "═══════════════════════════════════════════════════"