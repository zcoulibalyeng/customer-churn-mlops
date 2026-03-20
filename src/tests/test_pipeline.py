"""
Unit Tests for Customer Churn MLOps Pipeline

Tests cover:
  1. Data loading and feature encoding
  2. Model training produces valid artifacts
  3. Inference handler returns correct response format
  4. Lambda handler validates input correctly
"""

import json
import os
import sys
import tempfile

import numpy as np
import pandas as pd
import pytest

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))


# ─── Test Data Fixtures ──────────────────────────────────────

@pytest.fixture
def sample_data():
    """Create minimal sample dataset matching bank_data.csv schema."""
    np.random.seed(42)
    n = 200
    return pd.DataFrame({
        "CLIENTNUM": range(n),
        "Attrition_Flag": np.random.choice(
            ["Existing Customer", "Attrited Customer"], n, p=[0.84, 0.16]
        ),
        "Customer_Age": np.random.randint(25, 70, n),
        "Gender": np.random.choice(["M", "F"], n),
        "Dependent_count": np.random.randint(0, 6, n),
        "Education_Level": np.random.choice(
            ["Graduate", "High School", "Unknown", "College"], n
        ),
        "Marital_Status": np.random.choice(
            ["Married", "Single", "Unknown"], n
        ),
        "Income_Category": np.random.choice(
            ["Less than $40K", "$40K - $60K", "$60K - $80K"], n
        ),
        "Card_Category": np.random.choice(["Blue", "Silver", "Gold"], n),
        "Months_on_book": np.random.randint(12, 56, n),
        "Total_Relationship_Count": np.random.randint(1, 7, n),
        "Months_Inactive_12_mon": np.random.randint(0, 7, n),
        "Contacts_Count_12_mon": np.random.randint(0, 6, n),
        "Credit_Limit": np.random.uniform(1000, 35000, n),
        "Total_Revolving_Bal": np.random.uniform(0, 3000, n),
        "Avg_Open_To_Buy": np.random.uniform(0, 32000, n),
        "Total_Amt_Chng_Q4_Q1": np.random.uniform(0, 4, n),
        "Total_Trans_Amt": np.random.uniform(500, 20000, n),
        "Total_Trans_Ct": np.random.randint(10, 140, n),
        "Total_Ct_Chng_Q4_Q1": np.random.uniform(0, 4, n),
        "Avg_Utilization_Ratio": np.random.uniform(0, 1, n),
    })


@pytest.fixture
def sample_csv(sample_data, tmp_path):
    """Write sample data to a temporary CSV file."""
    path = tmp_path / "test_data.csv"
    sample_data.to_csv(path, index=True)
    return str(path)


# ─── Training Tests ──────────────────────────────────────────

class TestTraining:
    def test_load_data(self, sample_csv):
        from src.training.train import load_data
        df = load_data(sample_csv)
        assert "Churn" in df.columns
        assert set(df["Churn"].unique()).issubset({0, 1})
        assert len(df) == 200

    def test_encode_features(self, sample_csv):
        from src.training.train import load_data, encode_features
        df = load_data(sample_csv)
        df_encoded = encode_features(df)

        # Check all encoded columns exist
        for col in ["Gender", "Education_Level", "Marital_Status",
                     "Income_Category", "Card_Category"]:
            assert f"{col}_Churn" in df_encoded.columns
            # Encoded values should be proportions between 0 and 1
            assert df_encoded[f"{col}_Churn"].between(0, 1).all()

    def test_full_training(self, sample_csv):
        from src.training.train import train

        with tempfile.TemporaryDirectory() as output_dir:
            # Use small param grid for fast test
            metrics = train(
                data_path=sample_csv,
                output_dir=output_dir,
                hyperparams={"n_estimators": [10], "max_depth": [3],
                             "max_features": ["sqrt"], "criterion": ["gini"]},
            )

            # Check artifacts exist
            assert os.path.exists(os.path.join(output_dir, "rfc_model.pkl"))
            assert os.path.exists(os.path.join(output_dir, "logistic_model.pkl"))
            assert os.path.exists(os.path.join(output_dir, "scaler.pkl"))
            assert os.path.exists(os.path.join(output_dir, "metrics.json"))

            # Check metrics structure
            assert "random_forest" in metrics
            assert "f1_score" in metrics["random_forest"]
            assert 0 <= metrics["random_forest"]["f1_score"] <= 1


# ─── Inference Tests ─────────────────────────────────────────

class TestInference:
    def test_feature_columns_count(self):
        from src.serving.inference import FEATURE_COLUMNS
        assert len(FEATURE_COLUMNS) == 19

    def test_feature_columns_match_training(self):
        from src.serving.inference import FEATURE_COLUMNS
        from src.training.train import KEEP_COLUMNS
        assert FEATURE_COLUMNS == KEEP_COLUMNS, (
            "Inference features must match training features exactly"
        )


# ─── Lambda Handler Tests ────────────────────────────────────

class TestLambdaHandler:
    def test_health_endpoint(self):
        # Minimal test that validates the handler routing logic
        os.environ["SAGEMAKER_ENDPOINT"] = "test-endpoint"
        from src.serving.lambda_handler import handler

        event = {"path": "/health", "httpMethod": "GET"}
        response = handler(event, None)
        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["status"] == "healthy"

    def test_predict_missing_instances(self):
        os.environ["SAGEMAKER_ENDPOINT"] = "test-endpoint"
        from src.serving.lambda_handler import handler

        event = {
            "path": "/predict",
            "httpMethod": "POST",
            "body": json.dumps({"wrong_key": []}),
        }
        response = handler(event, None)
        assert response["statusCode"] == 400

    def test_predict_wrong_feature_count(self):
        os.environ["SAGEMAKER_ENDPOINT"] = "test-endpoint"
        from src.serving.lambda_handler import handler

        event = {
            "path": "/predict",
            "httpMethod": "POST",
            "body": json.dumps({"instances": [[1, 2, 3]]}),  # Only 3 features
        }
        response = handler(event, None)
        assert response["statusCode"] == 400
        assert "19 features" in json.loads(response["body"])["error"]

    def test_404_on_unknown_path(self):
        os.environ["SAGEMAKER_ENDPOINT"] = "test-endpoint"
        from src.serving.lambda_handler import handler

        event = {"path": "/unknown", "httpMethod": "GET"}
        response = handler(event, None)
        assert response["statusCode"] == 404
