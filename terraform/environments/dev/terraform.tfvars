# ═══════════════════════════════════════════════════════════════
# Dev Environment Configuration
#
# WHY THESE VALUES:
# - 1 instance (no HA needed in dev, saves ~$300/month)
# - ml.m5.large (smallest viable for sklearn RF model)
# - Monitoring OFF (saves processing job costs in dev)
# ═══════════════════════════════════════════════════════════════

project_name       = "customer-churn"
environment        = "dev"
aws_region         = "us-east-1"
model_instance_type  = "ml.m5.large"
model_instance_count = 1
enable_monitoring  = false
alert_email        = "zcoulibalyeng@gmail.com"
