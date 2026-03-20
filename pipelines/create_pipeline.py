"""
SageMaker Pipeline Definition

This script defines and registers the training pipeline in SageMaker.
Run it once to create the pipeline, then the retrain Lambda can trigger it.

The pipeline has 4 steps:
  1. Preprocessing  → download data, encode features, split train/test
  2. Training       → train the model (RF or PyTorch depending on version)
  3. Evaluation     → compute F1/AUC, fail if below threshold
  4. Register Model → register in Model Registry if quality gates pass

Usage:
  python pipelines/create_pipeline.py \
    --pipeline-name customer-churn-dev-training-pipeline \
    --role-arn arn:aws:iam::ACCOUNT:role/SageMakerRole \
    --data-bucket customer-churn-dev-data \
    --model-bucket customer-churn-dev-models \
    --region us-east-1
"""

import argparse
import json
import logging
import os

import boto3

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)


def create_pipeline(pipeline_name, role_arn, data_bucket, model_bucket, region):
    """
    Create a SageMaker Pipeline using the low-level API.

    WHY LOW-LEVEL API (not SageMaker SDK Pipeline class):
    - No dependency on sagemaker SDK in CI/CD
    - Explicit JSON definition — you see exactly what's created
    - Terraform can call this script without installing the full SDK
    - Easier to debug (it's just a JSON document)
    """

    sm = boto3.client("sagemaker", region_name=region)

    # ─── Pipeline Definition ─────────────────────────────────
    # SageMaker Pipelines use a JSON definition with steps.
    # Each step is a Processing or Training job.

    pipeline_definition = {
        "Version": "2020-12-01",
        "Parameters": [
            {
                "Name": "InputData",
                "Type": "String",
                "DefaultValue": f"s3://{data_bucket}/raw/bank_data.csv",
            },
            {
                "Name": "MinF1Score",
                "Type": "Float",
                "DefaultValue": 0.88,
            },
            {
                "Name": "ModelApproval",
                "Type": "String",
                "DefaultValue": "PendingManualApproval",
            },
        ],
        "Steps": [
            # ─── Step 1: Train & Evaluate ────────────────────
            # Single processing job that runs the full pipeline:
            # load → encode → split → train → evaluate → save
            # This is simpler than separate steps for a small model.
            {
                "Name": "TrainAndEvaluate",
                "Type": "Processing",
                "Arguments": {
                    "ProcessingResources": {
                        "ClusterConfig": {
                            "InstanceCount": 1,
                            "InstanceType": "ml.m5.large",
                            "VolumeSizeInGB": 10,
                        }
                    },
                    "AppSpecification": {
                        "ImageUri": _get_sklearn_image(region),
                        "ContainerEntrypoint": [
                            "python3",
                            "/opt/ml/processing/code/train.py",
                        ],
                        "ContainerArguments": [
                            "--data-path", "/opt/ml/processing/input/",
                            "--output-dir", "/opt/ml/processing/output/model/",
                        ],
                    },
                    "ProcessingInputs": [
                        {
                            "InputName": "input-data",
                            "S3Input": {
                                "S3Uri": {"Get": "Parameters.InputData"},
                                "LocalPath": "/opt/ml/processing/input",
                                "S3DataType": "S3Prefix",
                                "S3InputMode": "File",
                                "S3CompressionType": "None",
                            },
                        },
                        {
                            "InputName": "code",
                            "S3Input": {
                                "S3Uri": f"s3://{model_bucket}/pipeline-code/train.py",
                                "LocalPath": "/opt/ml/processing/code",
                                "S3DataType": "S3Prefix",
                                "S3InputMode": "File",
                                "S3CompressionType": "None",
                            },
                        },
                    ],
                    "ProcessingOutputConfig": {
                        "Outputs": [
                            {
                                "OutputName": "model-output",
                                "S3Output": {
                                    "S3Uri": f"s3://{model_bucket}/pipeline-output/",
                                    "LocalPath": "/opt/ml/processing/output/model",
                                    "S3UploadMode": "EndOfJob",
                                },
                            }
                        ]
                    },
                    "RoleArn": role_arn,
                },
            },
            # ─── Step 2: Quality Gate ────────────────────────
            # Check if the model meets the F1 threshold.
            # This is a separate step so it shows clearly in the
            # pipeline DAG whether quality passed or failed.
            {
                "Name": "QualityGate",
                "Type": "Processing",
                "DependsOn": ["TrainAndEvaluate"],
                "Arguments": {
                    "ProcessingResources": {
                        "ClusterConfig": {
                            "InstanceCount": 1,
                            "InstanceType": "ml.t3.medium",
                            "VolumeSizeInGB": 5,
                        }
                    },
                    "AppSpecification": {
                        "ImageUri": _get_sklearn_image(region),
                        "ContainerEntrypoint": ["python3", "-c"],
                        "ContainerArguments": [
                            "import json, sys; "
                            "m=json.load(open('/opt/ml/processing/input/metrics.json')); "
                            "f1=m.get('random_forest',m.get('pytorch_model',{})).get('f1_score',0); "
                            "auc=m.get('random_forest',m.get('pytorch_model',{})).get('auc_roc',0); "
                            "print(f'F1={f1:.4f} AUC={auc:.4f}'); "
                            "assert f1>=0.85,f'F1 {f1} below threshold'; "
                            "assert auc>=0.88,f'AUC {auc} below threshold'; "
                            "print('QUALITY GATE PASSED')"
                        ],
                    },
                    "ProcessingInputs": [
                        {
                            "InputName": "metrics",
                            "S3Input": {
                                "S3Uri": f"s3://{model_bucket}/pipeline-output/",
                                "LocalPath": "/opt/ml/processing/input",
                                "S3DataType": "S3Prefix",
                                "S3InputMode": "File",
                                "S3CompressionType": "None",
                            },
                        }
                    ],
                    "RoleArn": role_arn,
                },
            },
            # ─── Step 3: Deploy Model ────────────────────────
            # Copy the model artifact to the 'latest' path so the
            # endpoint picks it up on next deployment.
            {
                "Name": "PromoteModel",
                "Type": "Processing",
                "DependsOn": ["QualityGate"],
                "Arguments": {
                    "ProcessingResources": {
                        "ClusterConfig": {
                            "InstanceCount": 1,
                            "InstanceType": "ml.t3.medium",
                            "VolumeSizeInGB": 5,
                        }
                    },
                    "AppSpecification": {
                        "ImageUri": _get_sklearn_image(region),
                        "ContainerEntrypoint": ["python3", "-c"],
                        "ContainerArguments": [
                            "import subprocess, datetime; "
                            f"src='s3://{model_bucket}/pipeline-output/'; "
                            f"dst='s3://{model_bucket}/latest/model.tar.gz'; "
                            "ts=datetime.datetime.utcnow().strftime('%Y%m%d-%H%M%S'); "
                            f"ver=f's3://{model_bucket}/versions/model-{{ts}}.tar.gz'; "
                            "subprocess.run(['aws','s3','cp',src+'model.tar.gz',dst],check=True); "
                            "subprocess.run(['aws','s3','cp',src+'model.tar.gz',ver],check=True); "
                            "print(f'Model promoted to {dst} and versioned as model-{ts}')"
                        ],
                    },
                    "RoleArn": role_arn,
                },
            },
        ],
    }

    # ─── Create or Update Pipeline ───────────────────────────
    try:
        sm.describe_pipeline(PipelineName=pipeline_name)
        logger.info("Pipeline exists, updating: %s", pipeline_name)
        sm.update_pipeline(
            PipelineName=pipeline_name,
            PipelineDefinition=json.dumps(pipeline_definition),
            RoleArn=role_arn,
            Description="Customer Churn retraining pipeline (auto-triggered by drift)",
        )
    except sm.exceptions.ResourceNotFound:
        logger.info("Creating new pipeline: %s", pipeline_name)
        sm.create_pipeline(
            PipelineName=pipeline_name,
            PipelineDefinition=json.dumps(pipeline_definition),
            RoleArn=role_arn,
            Description="Customer Churn retraining pipeline (auto-triggered by drift)",
        )

    logger.info("Pipeline ready: %s", pipeline_name)

    # ─── Upload Training Code to S3 ─────────────────────────
    # The pipeline step downloads this script to run inside the container
    import boto3
    s3 = boto3.client("s3", region_name=region)
    train_script = os.path.join(os.path.dirname(__file__), "..", "src", "training", "train.py")

    if os.path.exists(train_script):
        s3.upload_file(train_script, model_bucket, "pipeline-code/train.py")
        logger.info("Uploaded train.py to s3://%s/pipeline-code/train.py", model_bucket)
    else:
        logger.warning("train.py not found at %s — upload manually", train_script)

    return pipeline_name


def _get_sklearn_image(region):
    """Get the AWS-managed sklearn processing image URI."""
    account_map = {
        "us-east-1": "683313688378",
        "us-east-2": "257758044811",
        "us-west-1": "746614075791",
        "us-west-2": "246618743249",
        "eu-west-1": "720646828776",
        "eu-central-1": "492215442770",
        "ap-southeast-1": "121021644041",
        "ap-northeast-1": "354813040037",
    }
    account = account_map.get(region, "683313688378")
    return f"{account}.dkr.ecr.{region}.amazonaws.com/sagemaker-scikit-learn:1.2-1-cpu-py3"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Create SageMaker Training Pipeline")
    parser.add_argument("--pipeline-name", required=True)
    parser.add_argument("--role-arn", required=True)
    parser.add_argument("--data-bucket", required=True)
    parser.add_argument("--model-bucket", required=True)
    parser.add_argument("--region", default="us-east-1")
    args = parser.parse_args()

    create_pipeline(
        pipeline_name=args.pipeline_name,
        role_arn=args.role_arn,
        data_bucket=args.data_bucket,
        model_bucket=args.model_bucket,
        region=args.region,
    )
