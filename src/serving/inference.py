"""
SageMaker Inference Handler

This Flask app is what runs inside the SageMaker endpoint container.
SageMaker expects two routes:
  GET  /ping          → health check (return 200 if model is loaded)
  POST /invocations   → prediction endpoint

SageMaker extracts model.tar.gz to /opt/ml/model/ at container start.
The model loads ONCE at import time (not per request) for performance.
"""

import json
import logging
import os
import sys
import time
from datetime import datetime

import joblib
import numpy as np
import pandas as pd
from flask import Flask, Response, request

# ─── Logging ─────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# ─── Feature Schema ─────────────────────────────────────────
# These MUST match training exactly. If they drift, predictions are garbage.
FEATURE_COLUMNS = [
    "Customer_Age", "Dependent_count", "Months_on_book",
    "Total_Relationship_Count", "Months_Inactive_12_mon",
    "Contacts_Count_12_mon", "Credit_Limit", "Total_Revolving_Bal",
    "Avg_Open_To_Buy", "Total_Amt_Chng_Q4_Q1", "Total_Trans_Amt",
    "Total_Trans_Ct", "Total_Ct_Chng_Q4_Q1", "Avg_Utilization_Ratio",
    "Gender_Churn", "Education_Level_Churn", "Marital_Status_Churn",
    "Income_Category_Churn", "Card_Category_Churn",
]

# ─── Load Model at Container Startup ────────────────────────
MODEL_DIR = os.environ.get("SM_MODEL_DIR", "/opt/ml/model")
MODEL_VERSION = os.environ.get("MODEL_VERSION", "unknown")

try:
    model = joblib.load(os.path.join(MODEL_DIR, "rfc_model.pkl"))
    logger.info("Model loaded successfully from %s", MODEL_DIR)

    # Try loading metrics for response metadata
    metrics_path = os.path.join(MODEL_DIR, "metrics.json")
    if os.path.exists(metrics_path):
        with open(metrics_path) as f:
            model_metrics = json.load(f)
        logger.info("Model metrics: F1=%.4f AUC=%.4f",
                     model_metrics["random_forest"]["f1_score"],
                     model_metrics["random_forest"]["auc_roc"])
    else:
        model_metrics = {}

except Exception as e:
    logger.error("FATAL: Failed to load model: %s", str(e))
    model = None
    model_metrics = {}


@app.route("/ping", methods=["GET"])
def ping():
    """Health check. SageMaker calls this every 30s.
    Return 200 if model is loaded. 503 if not."""
    if model is not None:
        return Response(
            json.dumps({
                "status": "healthy",
                "model_version": MODEL_VERSION,
                "timestamp": datetime.utcnow().isoformat(),
            }),
            status=200,
            mimetype="application/json",
        )
    return Response(
        json.dumps({"status": "unhealthy", "error": "Model not loaded"}),
        status=503,
        mimetype="application/json",
    )


@app.route("/invocations", methods=["POST"])
def invocations():
    """Prediction endpoint.

    Expects JSON:
    {
        "instances": [[45, 3, 39, 5, 1, 3, 12691, 777, ...], ...]
    }

    Returns JSON:
    {
        "predictions": [0, 1, ...],
        "probabilities": [0.12, 0.87, ...],
        "model_version": "v3.1",
        "latency_ms": 2.3
    }
    """
    start_time = time.time()

    # ─── Validate Request ────────────────────────────────────
    if model is None:
        return Response(
            json.dumps({"error": "Model not loaded"}),
            status=503,
            mimetype="application/json",
        )

    content_type = request.content_type
    if content_type != "application/json":
        return Response(
            json.dumps({"error": f"Unsupported content type: {content_type}"}),
            status=415,
            mimetype="application/json",
        )

    try:
        data = request.get_json(force=True)
    except Exception:
        return Response(
            json.dumps({"error": "Invalid JSON body"}),
            status=400,
            mimetype="application/json",
        )

    instances = data.get("instances")
    if instances is None:
        return Response(
            json.dumps({"error": "Missing 'instances' key in request body"}),
            status=400,
            mimetype="application/json",
        )

    # ─── Validate Features ───────────────────────────────────
    try:
        df = pd.DataFrame(instances, columns=FEATURE_COLUMNS)
    except ValueError as e:
        return Response(
            json.dumps({
                "error": f"Feature mismatch: expected {len(FEATURE_COLUMNS)} features, "
                         f"got {len(instances[0]) if instances else 0}. "
                         f"Detail: {str(e)}"
            }),
            status=400,
            mimetype="application/json",
        )

    # ─── Predict ─────────────────────────────────────────────
    try:
        probabilities = model.predict_proba(df)[:, 1]
        predictions = (probabilities >= 0.5).astype(int)
        latency_ms = round((time.time() - start_time) * 1000, 2)

        result = {
            "predictions": predictions.tolist(),
            "probabilities": [round(p, 4) for p in probabilities.tolist()],
            "model_version": MODEL_VERSION,
            "latency_ms": latency_ms,
            "batch_size": len(instances),
        }

        logger.info("Predicted %d samples in %.2fms (churn_rate=%.2f)",
                     len(instances), latency_ms,
                     predictions.mean())

        return Response(
            json.dumps(result),
            status=200,
            mimetype="application/json",
        )

    except Exception as e:
        logger.error("Prediction error: %s", str(e), exc_info=True)
        return Response(
            json.dumps({"error": f"Prediction failed: {str(e)}"}),
            status=500,
            mimetype="application/json",
        )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
