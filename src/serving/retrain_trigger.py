"""
Retrain Trigger Lambda

Invoked by SNS when Model Monitor detects data drift.
Starts a new SageMaker Pipeline execution to retrain the model.

CHAIN: Model Monitor → CloudWatch Alarm → SNS → THIS LAMBDA → SageMaker Pipeline
"""

import json
import logging
import os
from datetime import datetime

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

PIPELINE_NAME = os.environ["PIPELINE_NAME"]
DATA_BUCKET = os.environ["DATA_BUCKET"]

sm = boto3.client("sagemaker")


def handler(event, context):
    """Parse SNS notification and start retraining pipeline."""

    logger.info("Retrain trigger received: %s", json.dumps(event))

    # Parse the SNS message
    sns_message = event.get("Records", [{}])[0].get("Sns", {}).get("Message", "{}")

    try:
        execution = sm.start_pipeline_execution(
            PipelineName=PIPELINE_NAME,
            PipelineParameters=[
                {
                    "Name": "InputData",
                    "Value": f"s3://{DATA_BUCKET}/raw/",
                },
                {
                    "Name": "MinF1Score",
                    "Value": "0.88",
                },
                {
                    "Name": "ModelApproval",
                    "Value": "PendingManualApproval",
                },
            ],
            PipelineExecutionDescription=(
                f"Auto-triggered by drift detection at {datetime.utcnow().isoformat()}"
            ),
        )

        execution_arn = execution["PipelineExecutionArn"]
        logger.info("Pipeline started: %s", execution_arn)

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Retraining pipeline started",
                "execution_arn": execution_arn,
            }),
        }

    except Exception as e:
        logger.error("Failed to start pipeline: %s", str(e), exc_info=True)
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)}),
        }
