# ═══════════════════════════════════════════════════════════════
# Production Environment Configuration
#
# WHY THESE VALUES:
# - 2 instances minimum (multi-AZ high availability)
# - ml.m5.xlarge (4 vCPU, 16GB - headroom for RF model + gunicorn workers)
# - Monitoring ON (hourly drift detection, mandatory in prod)
# ═══════════════════════════════════════════════════════════════

project_name       = "customer-churn"
environment        = "prod-codemon-99"
aws_region         = "us-east-1"
model_instance_type  = "ml.m5.xlarge"
model_instance_count = 2
enable_monitoring  = true
alert_email        = "zcoulibalyeng@gmail.com"
