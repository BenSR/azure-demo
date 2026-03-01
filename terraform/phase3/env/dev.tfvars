# ─────────────────────────────────────────────────────────────────────────────
# dev.tfvars — dev workspace overrides for phase3
#
# Usage:
#   terraform -chdir=terraform/phase3/env workspace select dev
#   terraform -chdir=terraform/phase3/env apply \
#     -var-file=terraform.tfvars -var-file=dev.tfvars
#
# stamp_name values must match the stamps deployed by phase1/env in the dev
# workspace.  Phase 3 looks up function_app_hostnames, key_vault_ids, and
# app_insights_ids from the phase1/env remote state using these keys.
# ─────────────────────────────────────────────────────────────────────────────

stamps = [
  { stamp_name = "1" },
  { stamp_name = "2" },
]

# Alert thresholds — more permissive in dev to reduce noise.
alert_5xx_failure_threshold          = 10
alert_5xx_window_minutes             = 15
alert_availability_threshold_percent = 95.0
