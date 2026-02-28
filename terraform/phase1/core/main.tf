# ─── Shared locals ────────────────────────────────────────────────────────────

locals {
  # Single name suffix for all core resources.  No environment or workload
  # qualifier — core is deployed once and shared across all environments.
  name_suffix = "core"

  # Standard tags applied to every resource in Phase 1 core.
  tags = {
    layer      = "core"
    managed_by = "terraform"
    project    = "azure-demo"
  }

  # ── Hard-coded network layout ──────────────────────────────────────────────
  # Core owns a single /16 VNet.  Fixed shared subnets live here; stamp
  # subnets are passed explicitly via var.stamp_subnets.
  #
  # VNet: 10.100.0.0/16
  #
  # Fixed subnets (starting at .128 to leave room for stamps):
  #   runner    → 10.100.128.0/24
  #   jumpbox   → 10.100.129.0/27
  #   apim      → 10.100.129.32/27
  #   shared_pe → 10.100.130.0/24

  vnet_address_space = "10.100.0.0/16"

  subnet_cidrs = {
    runner    = "10.100.128.0/24"
    jumpbox   = "10.100.129.0/27"
    apim      = "10.100.129.32/27"
    shared_pe = "10.100.130.0/24"
  }
}
