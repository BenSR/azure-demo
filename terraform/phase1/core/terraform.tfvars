# ─────────────────────────────────────────────────────────────────────────────
# phase1/core — non-secret configuration
#
# Core is deployed once (no Terraform workspaces).  All values live here.
#
# Typical apply workflow:
#   terraform -chdir=terraform/phase1/core apply
#
# Sensitive values are NOT stored here.
#
# Provider auth (OIDC in CI, CLI locally) is configured via ARM_* env vars —
# never in this file.
# ─────────────────────────────────────────────────────────────────────────────

# ─── Subscription / tenant ───────────────────────────────────────────────────
# These values are also required as GitHub Actions secrets (ARM_SUBSCRIPTION_ID
# and ARM_TENANT_ID) for OIDC authentication.

subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "00000000-0000-0000-0000-000000000000"

# ─── Placement ───────────────────────────────────────────────────────────────

location = "uksouth"

# ─── Jump box ─────────────────────────────────────────────────────────────────

jumpbox_vm_size = "Standard_B2s"

# ─── Stamp subnets ────────────────────────────────────────────────────────────
# Each stamp gets a PE subnet (Private Endpoints) and an ASP subnet (App
# Service Plan VNet integration).  CIDRs must fall within 10.100.0.0/16.
#
# Add more entries to deploy additional stamps for any environment.

stamp_subnets = [
  {
    environment     = "dev"
    stamp_name      = "1"
    subnet_pe_cidr  = "10.100.0.0/24"
    subnet_asp_cidr = "10.100.1.0/24"
  },
  {
    environment     = "dev"
    stamp_name      = "2"
    subnet_pe_cidr  = "10.100.2.0/24"
    subnet_asp_cidr = "10.100.3.0/24"
  },
  {
    environment     = "prod"
    stamp_name      = "1"
    subnet_pe_cidr  = "10.100.6.0/24"
    subnet_asp_cidr = "10.100.7.0/24"
  },
]
