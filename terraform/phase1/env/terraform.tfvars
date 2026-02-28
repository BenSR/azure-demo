# ─────────────────────────────────────────────────────────────────────────────
# phase1/env — shared non-secret configuration
#
# Values that are the SAME across all workspaces (dev, prod).
# Environment-specific stamp definitions live in per-workspace files:
#
#   dev.tfvars   — used with: terraform workspace select dev
#   prod.tfvars  — used with: terraform workspace select prod
#
# Typical apply workflow (after phase1/core has been applied):
#   terraform -chdir=terraform/phase1/env workspace select dev
#   terraform -chdir=terraform/phase1/env apply \
#     -var-file=terraform.tfvars -var-file=dev.tfvars
#
# Provider auth (OIDC in CI, CLI locally) is configured via ARM_* env vars —
# never in this file.
# ─────────────────────────────────────────────────────────────────────────────

# ─── Subscription / tenant ───────────────────────────────────────────────────

subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "00000000-0000-0000-0000-000000000000"

# ─── Placement ───────────────────────────────────────────────────────────────

location = "uksouth"

# ─── Remote state — phase1/core ───────────────────────────────────────────────
# The storage account that holds Terraform state (in rg-wkld-deploy).
# Used to locate the phase1/core state file for this workspace.

state_storage_account_name = "<your-state-storage-account>"

# ─── APIM ────────────────────────────────────────────────────────────────────

apim_publisher_name  = "Platform Engineering"
apim_publisher_email = "platform@example.com"
