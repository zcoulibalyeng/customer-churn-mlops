.PHONY: help init plan apply destroy train deploy test lint clean

ENVIRONMENT ?= dev
AWS_REGION ?= us-east-1
PROJECT_NAME = customer-churn
TF_DIR = terraform/environments/$(ENVIRONMENT)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ─── Terraform ───────────────────────────────────────────────
init: ## Initialize Terraform for target environment
	cd $(TF_DIR) && terraform init

plan: ## Plan infrastructure changes
	cd $(TF_DIR) && terraform plan -var-file=terraform.tfvars -out=tfplan

apply: ## Apply infrastructure changes
	cd $(TF_DIR) && terraform apply tfplan

destroy: ## Destroy infrastructure (use with caution)
	cd $(TF_DIR) && terraform destroy -var-file=terraform.tfvars -auto-approve

# ─── Docker ──────────────────────────────────────────────────
build-training: ## Build training container
	docker build -t $(PROJECT_NAME)-training:latest -f containers/training/Dockerfile .

build-inference: ## Build inference container
	docker build -t $(PROJECT_NAME)-inference:latest -f containers/inference/Dockerfile .

build-all: build-training build-inference ## Build all containers

push-ecr: ## Push containers to ECR (requires AWS_ACCOUNT_ID)
	@if [ -z "$(AWS_ACCOUNT_ID)" ]; then echo "Set AWS_ACCOUNT_ID"; exit 1; fi
	aws ecr get-login-password --region $(AWS_REGION) | \
		docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
	docker tag $(PROJECT_NAME)-training:latest $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(PROJECT_NAME)-training:latest
	docker push $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(PROJECT_NAME)-training:latest
	docker tag $(PROJECT_NAME)-inference:latest $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(PROJECT_NAME)-inference:latest
	docker push $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(PROJECT_NAME)-inference:latest

# ─── ML Pipeline ─────────────────────────────────────────────
train-local: ## Train model locally
	python src/training/train.py --data-path data/bank_data.csv --output-dir models/

test-inference-local: ## Test inference container locally
	docker run -d --name churn-test -p 8080:8080 \
		-v $$(pwd)/models:/opt/ml/model $(PROJECT_NAME)-inference:latest
	sleep 3
	curl -s http://localhost:8080/ping | python -m json.tool
	curl -s -X POST http://localhost:8080/invocations \
		-H 'Content-Type: application/json' \
		-d '{"instances":[[45,3,39,5,1,3,12691,777,11914,1.335,1144,42,1.625,0.061,0.16,0.16,0.15,0.14,0.17]]}' \
		| python -m json.tool
	docker stop churn-test && docker rm churn-test

# ─── Code Quality ────────────────────────────────────────────
lint: ## Run linters
	black --check src/ tests/
	pylint src/ --fail-under=7.0
	bandit -r src/ -ll

format: ## Auto-format code
	black src/ tests/

test: ## Run tests
	pytest src/tests/ -v --tb=short

test-cov: ## Run tests with coverage
	pytest src/tests/ -v --cov=src --cov-report=html --cov-report=term

# ─── Utilities ───────────────────────────────────────────────
clean: ## Remove artifacts
	rm -rf models/*.pkl images/ __pycache__ .pytest_cache htmlcov/
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
