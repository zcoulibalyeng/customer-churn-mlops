# Customer Churn MLOps — Notebook to Production on AWS

> A complete, production-grade MLOps pipeline that takes a data scientist's churn prediction notebook and deploys it to AWS with Terraform, GitHub Actions, and zero console clicks.

```
Model: Random Forest (F1 ~0.91, AUC ~0.95)
Data:  10,127 credit card customers, 19 features
Stack: SageMaker · Terraform · GitHub Actions · CloudWatch
Scale: Auto-scales from 2 to 20 instances, p99 < 100ms
```

---

## What this repo does

You hand it a trained sklearn model. It gives you back:

- **A live HTTPS API** that returns churn predictions in <30ms
- **Automated retraining** when data drift is detected (or weekly on a schedule)
- **Canary deployments** — new models get 10% traffic for 10 minutes before full rollout, with auto-rollback if errors spike
- **Full observability** — CloudWatch dashboards, latency/error/drift alarms, PagerDuty integration
- **Network isolation** — everything runs in a VPC with private subnets, VPC endpoints, and security groups
- **CI/CD** — push code, get a deployed model. No manual steps.

---

## Architecture

```
Client
  │
  ▼
API Gateway (HTTPS, throttled)
  │
  ▼
Lambda (input validation, feature enrichment)
  │                                          ┌─────────────────────────┐
  ▼                                          │  VPC (10.0.0.0/16)     │
SageMaker Endpoint ◄─────────────────────────│  Private subnets (2 AZ)│
  ├── Champion variant (90%)                 │  Security groups        │
  └── Challenger variant (10%)               │  VPC Endpoints (7):     │
  │                                          │    S3, ECR, SageMaker,  │
  ▼                                          │    CloudWatch, STS      │
Model Monitor (hourly)                       └─────────────────────────┘
  │
  ├── Drift detected → SNS → Lambda → Retrain Pipeline
  └── Metrics → CloudWatch → Alarms → PagerDuty
```

---

## Project structure

```
customer-churn-mlops/
│
├── terraform/                          # Infrastructure as Code (8 modules, 77 resources)
│   ├── modules/
│   │   ├── iam/main.tf                 # Least-privilege roles for SageMaker + Lambda
│   │   ├── vpc/main.tf                 # VPC, subnets, security groups, VPC endpoints, flow logs
│   │   ├── s3/main.tf                  # 3 buckets: data, models, monitoring (all encrypted + versioned)
│   │   ├── ecr/main.tf                 # Container registries with scan-on-push + lifecycle policies
│   │   ├── sagemaker/main.tf           # Model, endpoint config, endpoint, auto-scaling, data capture
│   │   ├── lambda/main.tf              # Predict + retrain-trigger functions (VPC-attached)
│   │   ├── api-gateway/main.tf         # REST API with throttling
│   │   └── monitoring/main.tf          # 4 CloudWatch alarms, SNS topics, dashboard
│   └── environments/
│       ├── dev/                         # 1 instance, no NAT, monitoring off
│       │   ├── main.tf
│       │   └── terraform.tfvars
│       └── prod/                        # 2 instances, NAT gateways, monitoring on
│           ├── main.tf
│           └── terraform.tfvars
│
├── src/
│   ├── training/
│   │   └── train.py                    # Full pipeline: load → encode → GridSearchCV → evaluate → save
│   ├── serving/
│   │   ├── inference.py                # Flask app for SageMaker (GET /ping, POST /invocations)
│   │   ├── lambda_handler.py           # API Gateway → SageMaker routing with input validation
│   │   └── retrain_trigger.py          # SNS → SageMaker Pipeline trigger
│   └── tests/
│       └── test_pipeline.py            # 9 tests: training, inference, Lambda handler
│
├── containers/
│   ├── training/Dockerfile             # sklearn + pandas (training job)
│   └── inference/Dockerfile            # Flask + gunicorn + sklearn (SageMaker endpoint)
│
├── .github/workflows/
│   ├── ci.yml                          # PR: lint → test → build → terraform plan
│   ├── cd.yml                          # Merge: build → train → deploy dev → approve → deploy prod
│   └── retrain.yml                     # Weekly cron + manual trigger
│
├── scripts/
│   └── bootstrap.sh                    # One-time: create S3 state bucket + DynamoDB lock
│
├── data/                               # bank_data.csv (gitignored, lives in S3)
├── Makefile                            # Command shortcuts for everything
├── requirements.txt                    # Production dependencies
├── requirements-dev.txt                # Test/lint dependencies
└── .gitignore
```

---

## Prerequisites

| Tool | Version | Why |
|------|---------|-----|
| AWS CLI | v2+ | Terraform provider + bootstrap script |
| Terraform | >= 1.5 | Infrastructure provisioning |
| Python | 3.10+ | Training + Lambda + tests |
| Docker | 20+ | Container builds |
| Git | any | Version control + GitHub Actions trigger |
| GitHub account | — | CI/CD workflows + environment approvals |

You also need an AWS account with permissions to create: VPC, SageMaker, S3, ECR, Lambda, API Gateway, CloudWatch, IAM roles, and SNS topics.

---

## Setup — Step by step

### Step 1: Clone and configure

```bash
git clone https://github.com/your-org/customer-churn-mlops.git
cd customer-churn-mlops

# Create virtual environment
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
```

### Step 2: Add your training data

```bash
# Copy your bank_data.csv into the data directory
cp /path/to/bank_data.csv data/

# Verify it works
python src/training/train.py --data-path data/bank_data.csv --output-dir models/
# Expected output: RF F1 ~0.91, AUC ~0.95, artifacts saved to models/
```

### Step 3: Run tests locally

```bash
PYTHONPATH=. pytest src/tests/ -v
# Expected: 9 passed
```

### Step 4: Bootstrap AWS (one time only)

This creates the Terraform state backend. It's the only manual AWS step.

```bash
# Make sure AWS CLI is configured
aws sts get-caller-identity  # Should show your account

# Run bootstrap
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

This creates:
- `customer-churn-terraform-state` S3 bucket (versioned, encrypted)
- `terraform-lock` DynamoDB table (prevents concurrent terraform applies)
- Uploads `bank_data.csv` to dev and prod data buckets

### Step 5: Deploy dev infrastructure

```bash
cd terraform/environments/dev

terraform init          # Downloads providers, configures S3 backend
terraform plan -var-file=terraform.tfvars   # Preview what will be created
terraform apply -var-file=terraform.tfvars  # Create 77 AWS resources
```

First apply takes ~15 minutes (SageMaker endpoint creation is the bottleneck).

### Step 6: Build and push containers

```bash
# Back to repo root
cd ../../..

# Build locally
make build-all

# Push to ECR (set your account ID)
export AWS_ACCOUNT_ID=123456789012
make push-ecr
```

### Step 7: Test the live endpoint

```bash
# Get the API URL from Terraform output
cd terraform/environments/dev
API_URL=$(terraform output -raw api_endpoint)

# Health check
curl -s "${API_URL%predict}health" | python -m json.tool

# Prediction (a real customer from the dataset)
curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d '{"instances":[[45,3,39,5,1,3,12691,777,11914,1.335,1144,42,1.625,0.061,0.16,0.16,0.15,0.14,0.17]]}' \
  | python -m json.tool
```

Expected response:
```json
{
  "predictions": [0],
  "probabilities": [0.1234],
  "model_version": "terraform-managed",
  "latency_ms": 12.5,
  "batch_size": 1
}
```

### Step 8: Configure GitHub Actions

1. Go to **Settings → Secrets and variables → Actions** and add:

| Secret | Value | Used by |
|--------|-------|---------|
| `AWS_ACCOUNT_ID` | Your 12-digit account ID | Container tagging |
| `AWS_ROLE_ARN_CI` | IAM role ARN for CI (read-only) | `ci.yml` — terraform plan |
| `AWS_ROLE_ARN_CD` | IAM role ARN for CD (deploy) | `cd.yml` — terraform apply to dev |
| `AWS_ROLE_ARN_PROD` | IAM role ARN for prod deploy | `cd.yml` — terraform apply to prod |

2. Go to **Settings → Environments** and create:

| Environment | Protection rules |
|-------------|-----------------|
| `dev` | None (auto-deploys) |
| `production` | Required reviewers: add yourself or your team lead |

3. Push to `main`. The CD pipeline runs automatically.

---

## How CI/CD works

### On every Pull Request (`ci.yml`):

```
Lint (black + pylint + bandit)
  → Unit tests (9 tests, coverage report posted to PR)
    → Build containers (Docker build, no push)
      → Terraform plan (posted as PR comment)
```

Fails fast: if lint fails, nothing else runs.

### On merge to main (`cd.yml`):

```
Build & push containers to ECR (tagged with git SHA)
  → Package Lambda functions → S3
  → Train model (F1 >= 0.85 gate)
    → Terraform apply to DEV (automatic)
      → Smoke test dev endpoint
        → ⏸ Manual approval (GitHub environment gate)
          → Promote model + Lambda to prod S3
            → Terraform apply to PROD
              → Canary deployment (10% traffic, 10 min bake)
                → Full rollout or auto-rollback
```

### Weekly retraining (`retrain.yml`):

```
Every Monday 6 AM UTC (or manual trigger):
  Download latest data from S3
    → Train new model
      → Quality gate (F1 >= 0.85, AUC >= 0.88)
        → Upload to S3 → Update SageMaker endpoint
```

---

## Feature schema

The model expects exactly **19 features** in this order:

| # | Feature | Type | Description |
|---|---------|------|-------------|
| 1 | `Customer_Age` | int | Age of customer |
| 2 | `Dependent_count` | int | Number of dependents |
| 3 | `Months_on_book` | int | Months as customer |
| 4 | `Total_Relationship_Count` | int | Number of products held |
| 5 | `Months_Inactive_12_mon` | int | Inactive months (last 12) |
| 6 | `Contacts_Count_12_mon` | int | Customer service contacts |
| 7 | `Credit_Limit` | float | Credit limit |
| 8 | `Total_Revolving_Bal` | float | Revolving balance |
| 9 | `Avg_Open_To_Buy` | float | Available credit |
| 10 | `Total_Amt_Chng_Q4_Q1` | float | Transaction amount change |
| 11 | `Total_Trans_Amt` | float | Total transaction amount |
| 12 | `Total_Trans_Ct` | int | Total transaction count |
| 13 | `Total_Ct_Chng_Q4_Q1` | float | Transaction count change |
| 14 | `Avg_Utilization_Ratio` | float | Credit utilization |
| 15 | `Gender_Churn` | float | Target-encoded gender |
| 16 | `Education_Level_Churn` | float | Target-encoded education |
| 17 | `Marital_Status_Churn` | float | Target-encoded marital status |
| 18 | `Income_Category_Churn` | float | Target-encoded income |
| 19 | `Card_Category_Churn` | float | Target-encoded card type |

Features 15-19 are target-encoded: the churn rate of each category from the training data.

---

## Monitoring & alerts

| Alarm | Threshold | Severity | Action |
|-------|-----------|----------|--------|
| 5xx error rate | > 10 errors in 5 min | P1 (critical) | PagerDuty + email |
| p99 latency | > 100ms for 15 min | P2 (warning) | Email |
| No invocations | 0 requests for 15 min | P2 (warning) | Email |
| High CPU | > 80% for 15 min | P3 (info) | Dashboard |
| Data drift | Any feature violation | P2 | Auto-retrain pipeline |

CloudWatch dashboard: `customer-churn-{env}-dashboard`

---

## Cost estimates

| Component | Dev (monthly) | Prod (monthly) |
|-----------|--------------|----------------|
| SageMaker endpoint | ~$150 (1x ml.m5.large) | ~$600 (2x ml.m5.xlarge) |
| NAT Gateway | $0 (disabled) | ~$64 (2 AZs) |
| VPC Endpoints | ~$50 (7 interface endpoints) | ~$50 |
| S3 | ~$2 | ~$10 |
| ECR | ~$1 | ~$1 |
| Lambda | ~$0 (free tier) | ~$5 |
| CloudWatch | ~$3 | ~$15 |
| API Gateway | ~$0 (free tier) | ~$3.50/million requests |
| **Total** | **~$206/month** | **~$749/month** |

Cost optimization tips:
- Use SageMaker Savings Plans for 64% off baseline instances
- Use Spot instances for training jobs (90% off)
- Scale down dev endpoint outside business hours

---

## Makefile reference

```bash
make help                # Show all commands
make init                # terraform init (ENVIRONMENT=dev)
make plan                # terraform plan
make apply               # terraform apply
make build-all           # Build training + inference containers
make push-ecr            # Push containers to ECR
make train-local         # Train model locally
make test-inference-local # Test inference container with Docker
make lint                # black + pylint + bandit
make test                # pytest
make test-cov            # pytest with coverage report
make clean               # Remove artifacts
```

Set environment: `ENVIRONMENT=prod make plan`

---

## Destroying infrastructure

```bash
# Dev (safe to destroy anytime)
cd terraform/environments/dev
terraform destroy -var-file=terraform.tfvars

# Prod (think twice, then think again)
cd terraform/environments/prod
terraform destroy -var-file=terraform.tfvars
```

This removes all 77 AWS resources. S3 buckets with `force_destroy = false` (prod data bucket) will block destruction if they contain data — this is intentional.

---

## Adapting this for your own model

This repo is designed to work with **any sklearn model**. To swap in your own:

1. **Replace `data/bank_data.csv`** with your dataset
2. **Edit `src/training/train.py`**: update `CATEGORY_COLUMNS`, `KEEP_COLUMNS`, and the `PARAM_GRID` to match your features and model
3. **Edit `src/serving/inference.py`**: update `FEATURE_COLUMNS` to match (must be identical to `KEEP_COLUMNS`)
4. **Edit `src/tests/test_pipeline.py`**: update `sample_data()` fixture to match your schema
5. **Run tests**: `PYTHONPATH=. pytest src/tests/ -v` — all 9 should pass
6. **Push** — CI/CD handles the rest

For non-sklearn models (XGBoost, PyTorch, TensorFlow): update the Dockerfiles and `inference.py` to load your model format. Everything else (Terraform, CI/CD, monitoring) stays the same.

---

## Troubleshooting

**`terraform init` fails with "bucket does not exist"**
Run `scripts/bootstrap.sh` first. The S3 state bucket must exist before Terraform can use it.

**SageMaker endpoint stuck in "Creating"**
Check the model artifact exists: `aws s3 ls s3://customer-churn-dev-models/latest/model.tar.gz`
If missing, run `make train-local` then upload: `cd models && tar -czf model.tar.gz *.pkl *.json && aws s3 cp model.tar.gz s3://customer-churn-dev-models/latest/model.tar.gz`

**Lambda timeout / connection error**
The Lambda runs inside the VPC. It needs the SageMaker Runtime VPC endpoint to invoke the SageMaker endpoint. Verify the endpoint exists: `aws ec2 describe-vpc-endpoints --filters "Name=service-name,Values=*sagemaker.runtime*"`

**"No module named boto3" in tests**
Install it: `pip install boto3`

**Docker build fails on M1/M2 Mac**
Add `--platform linux/amd64` to the docker build command (SageMaker runs x86).

---

## License

Internal use. See your organization's policies.
