# ═══════════════════════════════════════════════════════════════
# Inference Container
#
# SageMaker Endpoints run this container.
# It must expose port 8080 with /ping and /invocations routes.
#
# Model artifacts are mounted at /opt/ml/model/ by SageMaker.
#
# WHY GUNICORN:
# - 4 workers = 4 parallel prediction threads
# - Pre-fork model: each worker loads the model once, not per request
# - Graceful shutdown on SIGTERM (SageMaker sends this during updates)
# ═══════════════════════════════════════════════════════════════

FROM python:3.10-slim

RUN pip install --no-cache-dir \
    flask==3.0.0 \
    gunicorn==21.2.0 \
    scikit-learn==1.4.1.post1 \
    pandas==2.2.1 \
    numpy==1.26.4 \
    joblib==1.3.2

# Copy inference code
COPY src/serving/inference.py /opt/ml/code/inference.py

WORKDIR /opt/ml/code

# SageMaker expects port 8080
EXPOSE 8080

# 4 workers, 60s timeout, graceful restart
ENTRYPOINT ["gunicorn", \
    "--bind", "0.0.0.0:8080", \
    "--workers", "4", \
    "--timeout", "60", \
    "--graceful-timeout", "30", \
    "--access-logfile", "-", \
    "inference:app"]
