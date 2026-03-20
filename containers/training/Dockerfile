# ═══════════════════════════════════════════════════════════════
# Training Container
#
# SageMaker runs this container as a training job.
# It mounts input data to /opt/ml/input/data/train/
# and expects the model output at /opt/ml/model/
#
# WHY CUSTOM CONTAINER (not built-in sklearn image):
# - Pin exact library versions for reproducibility
# - Include custom preprocessing code
# - Smaller image = faster cold starts
# ═══════════════════════════════════════════════════════════════

FROM python:3.10-slim

# Install only what training needs (no Flask, no gunicorn)
RUN pip install --no-cache-dir \
    scikit-learn==1.4.1.post1 \
    pandas==2.2.1 \
    numpy==1.26.4 \
    joblib==1.3.2 \
    boto3

# Copy training code
COPY src/training/ /opt/ml/code/

WORKDIR /opt/ml/code

# SageMaker Training entrypoint
ENV SAGEMAKER_PROGRAM=train.py

ENTRYPOINT ["python", "train.py"]
