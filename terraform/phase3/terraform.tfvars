# ─────────────────────────────────────────────────────────────────────────────
# phase3 — shared non-secret configuration
#
# Values that are the SAME across all workspaces (dev, prod).
# Workspace-specific stamp lists live in the per-workspace files:
#
#   dev.tfvars   — used with: terraform workspace select dev
#   prod.tfvars  — used with: terraform workspace select prod
#
# Typical apply workflow (after phase1/core and phase1/env have been applied):
#
#   terraform -chdir=terraform/phase3 workspace select dev
#   terraform -chdir=terraform/phase3 apply \
#     -var-file=terraform.tfvars -var-file=dev.tfvars
#
# Phase 3 MUST run on the VNet-injected GitHub runner (snet-runner) — it
# reaches Key Vault and APIM via Private Endpoints that are not accessible
# from public GitHub-hosted runners.
#
# Provider auth (OIDC in CI, CLI locally) is configured via ARM_* env vars —
# never in this file.
# ─────────────────────────────────────────────────────────────────────────────

# ─── Subscription / tenant ───────────────────────────────────────────────────

subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "00000000-0000-0000-0000-000000000000"

# ─── Remote state ────────────────────────────────────────────────────────────

state_storage_account_name = "<your-state-storage-account>"

# ─── APIM — API Operations ───────────────────────────────────────────────────
# Default operations expose a health-check GET and a generic POST endpoint.
# Override in a workspace-specific .tfvars if the API contract differs per env.

api_operations = [
  {
    operation_id = "health-check"
    display_name = "Health Check"
    http_method  = "GET"
    url_template = "/health"
  },
  {
    operation_id = "post-message"
    display_name = "Post Message"
    http_method  = "POST"
    url_template = "/message"
  },
]

# ─── Alerting ─────────────────────────────────────────────────────────────────

alert_email_receivers = ["platform@example.com"]
