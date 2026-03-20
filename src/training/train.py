"""
Production Training Script for Customer Churn Model

This script is designed to run inside a SageMaker Training Job container.
SageMaker sets environment variables that tell the script where to find
data and where to write the model:

  SM_CHANNEL_TRAIN  → /opt/ml/input/data/train/  (input CSV)
  SM_MODEL_DIR      → /opt/ml/model/              (output model artifacts)
  SM_OUTPUT_DIR     → /opt/ml/output/              (output logs, metrics)

When running locally, pass --data-path and --output-dir instead.
"""

import argparse
import json
import logging
import os
import sys
from datetime import datetime, timezone

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score,
    classification_report,
    f1_score,
    roc_auc_score,
)
from sklearn.model_selection import GridSearchCV, train_test_split
from sklearn.preprocessing import StandardScaler

# ─── Configuration ───────────────────────────────────────────
# These match the original notebook EXACTLY. Changing any of these
# will produce a different model. Document any changes.

RANDOM_STATE = 42
TEST_SIZE = 0.3

CATEGORY_COLUMNS = [
    "Gender",
    "Education_Level",
    "Marital_Status",
    "Income_Category",
    "Card_Category",
]

KEEP_COLUMNS = [
    "Customer_Age", "Dependent_count", "Months_on_book",
    "Total_Relationship_Count", "Months_Inactive_12_mon",
    "Contacts_Count_12_mon", "Credit_Limit", "Total_Revolving_Bal",
    "Avg_Open_To_Buy", "Total_Amt_Chng_Q4_Q1", "Total_Trans_Amt",
    "Total_Trans_Ct", "Total_Ct_Chng_Q4_Q1", "Avg_Utilization_Ratio",
    "Gender_Churn", "Education_Level_Churn", "Marital_Status_Churn",
    "Income_Category_Churn", "Card_Category_Churn",
]

PARAM_GRID = {
    "n_estimators": [200, 500],
    "max_features": ["sqrt", "log2"],
    "max_depth": [4, 5, 100],
    "criterion": ["gini", "entropy"],
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


def load_data(path: str) -> pd.DataFrame:
    """Load CSV and create binary Churn target."""
    logger.info("Loading data from %s", path)
    df = pd.read_csv(path, index_col=0)
    df["Churn"] = df["Attrition_Flag"].apply(
        lambda val: 0 if val == "Existing Customer" else 1
    )
    logger.info("Data shape: %s | Churn rate: %.2f%%",
                df.shape, df["Churn"].mean() * 100)
    return df


def encode_features(df: pd.DataFrame) -> pd.DataFrame:
    """Target-encode categorical features (mean of Churn per category)."""
    df_encoded = df.copy()
    for col in CATEGORY_COLUMNS:
        means = df_encoded.groupby(col)["Churn"].mean()
        df_encoded[f"{col}_Churn"] = df_encoded[col].map(means)
        logger.info("Encoded %s → %s_Churn (unique=%d)",
                     col, col, df_encoded[col].nunique())
    return df_encoded


def train(data_path: str, output_dir: str, hyperparams: dict = None):
    """Full training pipeline: load → encode → split → train → evaluate → save."""

    # ─── Step 1: Load & Encode ───────────────────────────────
    df = load_data(data_path)
    df = encode_features(df)

    y = df["Churn"]
    X = df[KEEP_COLUMNS]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=TEST_SIZE, random_state=RANDOM_STATE
    )
    logger.info("Train: %d samples | Test: %d samples", len(X_train), len(X_test))

    # ─── Step 2: Train Random Forest (champion) ─────────────
    param_grid = hyperparams or PARAM_GRID
    logger.info("Starting GridSearchCV with params: %s", param_grid)

    rfc = RandomForestClassifier(random_state=RANDOM_STATE)
    cv_rfc = GridSearchCV(
        estimator=rfc,
        param_grid=param_grid,
        cv=5,
        n_jobs=-1,
        scoring="f1",
        verbose=1,
    )
    cv_rfc.fit(X_train, y_train)
    best_rf = cv_rfc.best_estimator_
    logger.info("Best RF params: %s", cv_rfc.best_params_)

    # ─── Step 3: Train Logistic Regression (challenger) ──────
    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_test_scaled = scaler.transform(X_test)

    lrc = LogisticRegression(
        solver="lbfgs", max_iter=3000, random_state=RANDOM_STATE
    )
    lrc.fit(X_train_scaled, y_train)

    # ─── Step 4: Evaluate ────────────────────────────────────
    rf_preds = best_rf.predict(X_test)
    rf_probs = best_rf.predict_proba(X_test)[:, 1]
    lr_preds = lrc.predict(X_test_scaled)
    lr_probs = lrc.predict_proba(X_test_scaled)[:, 1]

    metrics = {
        "random_forest": {
            "accuracy": float(accuracy_score(y_test, rf_preds)),
            "f1_score": float(f1_score(y_test, rf_preds)),
            "auc_roc": float(roc_auc_score(y_test, rf_probs)),
        },
        "logistic_regression": {
            "accuracy": float(accuracy_score(y_test, lr_preds)),
            "f1_score": float(f1_score(y_test, lr_preds)),
            "auc_roc": float(roc_auc_score(y_test, lr_probs)),
        },
        "best_params": cv_rfc.best_params_,
        "training_timestamp": datetime.now(timezone.utc).isoformat(),
        "data_samples": len(df),
        "feature_count": len(KEEP_COLUMNS),
    }

    logger.info("RF  → Accuracy: %.4f | F1: %.4f | AUC: %.4f",
                metrics["random_forest"]["accuracy"],
                metrics["random_forest"]["f1_score"],
                metrics["random_forest"]["auc_roc"])
    logger.info("LR  → Accuracy: %.4f | F1: %.4f | AUC: %.4f",
                metrics["logistic_regression"]["accuracy"],
                metrics["logistic_regression"]["f1_score"],
                metrics["logistic_regression"]["auc_roc"])

    # ─── Step 5: Save Artifacts ──────────────────────────────
    os.makedirs(output_dir, exist_ok=True)

    joblib.dump(best_rf, os.path.join(output_dir, "rfc_model.pkl"))
    joblib.dump(lrc, os.path.join(output_dir, "logistic_model.pkl"))
    joblib.dump(scaler, os.path.join(output_dir, "scaler.pkl"))

    # Save metrics for SageMaker Pipeline condition evaluation
    with open(os.path.join(output_dir, "metrics.json"), "w") as f:
        json.dump(metrics, f, indent=2)

    # Save feature columns list (used by inference container for validation)
    with open(os.path.join(output_dir, "feature_columns.json"), "w") as f:
        json.dump(KEEP_COLUMNS, f)

    logger.info("All artifacts saved to %s", output_dir)
    return metrics


if __name__ == "__main__":
    parser = argparse.ArgumentParser()

    # SageMaker environment variables (set automatically in training jobs)
    parser.add_argument("--data-path", type=str,
                        default=os.environ.get("SM_CHANNEL_TRAIN", "data/bank_data.csv"))
    parser.add_argument("--output-dir", type=str,
                        default=os.environ.get("SM_MODEL_DIR", "models/"))

    # Hyperparameter overrides
    parser.add_argument("--n-estimators", type=str, default=None)
    parser.add_argument("--max-depth", type=str, default=None)

    args = parser.parse_args()

    # Handle SageMaker's directory-based data input
    data_path = args.data_path
    if os.path.isdir(data_path):
        csv_files = [f for f in os.listdir(data_path) if f.endswith(".csv")]
        if csv_files:
            data_path = os.path.join(data_path, csv_files[0])

    train(data_path=data_path, output_dir=args.output_dir)
