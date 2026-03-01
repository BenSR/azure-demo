# ─────────────────────────────────────────────────────────────────────────────
# prod.tfvars — prod workspace overrides for phase3
#
# Usage:
#   terraform -chdir=terraform/phase3/env workspace select prod
#   terraform -chdir=terraform/phase3/env apply \
#     -var-file=terraform.tfvars -var-file=prod.tfvars
# ─────────────────────────────────────────────────────────────────────────────

stamps = [
  { stamp_name = "1" },
]

# Alert thresholds — strictest for production.
alert_5xx_failure_threshold          = 3
alert_5xx_window_minutes             = 5
alert_availability_threshold_percent = 99.9
