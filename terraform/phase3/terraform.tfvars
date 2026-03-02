# ─────────────────────────────────────────────────────────────────────────────
# phase3 — shared non-secret configuration
#
# Phase 3 is a single (non-workspace) deployment that creates the Application
# Gateway.  It reads remote state from phase1/core and phase1/env workspaces
# to discover APIM endpoints.
#
# Deployment:
#   terraform -chdir=terraform/phase3 init -backend-config=backend.hcl
#   terraform -chdir=terraform/phase3 apply
#
# Secrets (state_storage_account_name) are passed via environment variables
# or -var flags — never stored in this file.
# ─────────────────────────────────────────────────────────────────────────────

location = "northeurope"

environments = ["dev", "prod"]

appgw_subnet_cidr  = "10.100.131.0/27"
appgw_sku          = "Standard_v2"
appgw_min_capacity = 1
appgw_max_capacity = 2
