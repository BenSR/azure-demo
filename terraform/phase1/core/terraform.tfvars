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
# ARM_SUBSCRIPTION_ID and ARM_TENANT_ID are required as GitHub Actions secrets
# for OIDC authentication — they are picked up automatically by the provider.

subscription_id = "00000000-0000-0000-0000-000000000000"

# ─── Placement ───────────────────────────────────────────────────────────────

location = "uksouth"

# ─── Jump box ─────────────────────────────────────────────────────────────────

jumpbox_vm_size = "Standard_B2s"

# ─── Self-hosted runner ────────────────────────────────────────────────────────
# runner_admin_upn: the Entra ID user who receives "Virtual Machine Administrator
# Login" on the runner VM, enabling SSH via `az ssh vm` from the jumpbox.

runner_vm_size   = "Standard_B2s"
runner_admin_upn = "ben.somerville.roberts_outlook.com#EXT#@bensomervillerobertsoutlook.onmicrosoft.com"

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
