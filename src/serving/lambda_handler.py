"""
Lambda Handler: API Gateway → SageMaker Endpoint

This Lambda sits between API Gateway and SageMaker.
It validates input, invokes the endpoint, and formats the response.

WHY NOT CALL SAGEMAKER DIRECTLY FROM API GATEWAY:
- API Gateway's AWS_PROXY integration with SageMaker is limited
- No input validation (bad data = wasted compute)
- No response transformation (SageMaker returns raw bytes)
- No custom error handling or logging
- No rate limiting per client
"""

import json
import logging
import os
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SAGEMAKER_ENDPOINT = os.environ.get("SAGEMAKER_ENDPOINT", "")
EXPECTED_FEATURE_COUNT = 19

# Lazy init: only create the client when actually invoking SageMaker
# This allows unit tests to import the module without AWS credentials
_runtime = None

def _get_runtime():
    global _runtime
    if _runtime is None:
        _runtime = boto3.client("sagemaker-runtime", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    return _runtime


def handler(event, context):
    """Main Lambda handler. Handles both /predict and /health routes."""

    path = event.get("path", "")
    method = event.get("httpMethod", "")

    # ─── Health Check ────────────────────────────────────────
    if path == "/health" and method == "GET":
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "status": "healthy",
                "endpoint": SAGEMAKER_ENDPOINT,
                "timestamp": time.time(),
            }),
        }

    # ─── Prediction ──────────────────────────────────────────
    if path == "/predict" and method == "POST":
        return _handle_predict(event)

    return {
        "statusCode": 404,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": f"Not found: {method} {path}"}),
    }


def _handle_predict(event):
    """Validate input, invoke SageMaker, return formatted response."""
    start = time.time()

    # ─── Parse Body ──────────────────────────────────────────
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        return _error(400, "Invalid JSON in request body")

    instances = body.get("instances")
    if not instances:
        return _error(400, "Missing 'instances' key. Expected: {\"instances\": [[f1, f2, ...]]}")

    if not isinstance(instances, list) or not isinstance(instances[0], list):
        return _error(400, "instances must be a list of lists (each inner list = 19 features)")

    # ─── Validate Feature Count ──────────────────────────────
    for i, row in enumerate(instances):
        if len(row) != EXPECTED_FEATURE_COUNT:
            return _error(400,
                f"Row {i}: expected {EXPECTED_FEATURE_COUNT} features, got {len(row)}")

    # ─── Invoke SageMaker ────────────────────────────────────
    try:
        response = _get_runtime().invoke_endpoint(
            EndpointName=SAGEMAKER_ENDPOINT,
            ContentType="application/json",
            Body=json.dumps({"instances": instances}),
        )
        result = json.loads(response["Body"].read().decode())

        latency_ms = round((time.time() - start) * 1000, 2)
        result["total_latency_ms"] = latency_ms

        logger.info("Predicted %d samples in %.2fms", len(instances), latency_ms)

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "X-Model-Version": result.get("model_version", "unknown"),
                "X-Latency-Ms": str(latency_ms),
            },
            "body": json.dumps(result),
        }

    except Exception as me:
        if "ModelError" in type(me).__name__:
            logger.error("SageMaker ModelError: %s", str(me))
            return _error(502, f"Model prediction failed: {str(me)}")
        logger.error("SageMaker invoke failed: %s", str(me), exc_info=True)
        return _error(500, f"Internal error: {str(me)}")


def _error(status_code, message):
    """Helper to return error responses."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
