# ─────────────────────────────────────────────────────────────────────────────
# phase3 — shared non-secret configuration
#
# Values that are the SAME across all workspaces (dev, prod).
# Workspace-specific stamp lists live in the per-workspace files:


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
