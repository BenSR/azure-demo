# ─── Shared locals ────────────────────────────────────────────────────────────

locals {
  workload = "wkld"

  # Environment is driven by the Terraform workspace name — must match the
  # workspace used when applying phase1/env/ so that remote state resolves.
  environment = terraform.workspace == "default" ? "dev" : terraform.workspace

  tags = {
    workload    = local.workload
    environment = local.environment
    workspace   = terraform.workspace
    managed_by  = "terraform"
    project     = "azure-demo"
    phase       = "2"
  }

  # Aliases for remote state outputs — keeps resource definitions readable.
  core = data.terraform_remote_state.core.outputs
  env  = data.terraform_remote_state.env.outputs

  # Stamps map keyed by stamp_name for use in for_each.
  stamps_map = { for s in var.stamps : s.stamp_name => s }

  # ── APIM identity ─────────────────────────────────────────────────────────
  # Derived from the same naming convention used in phase1/env to avoid
  # requiring an extra remote state output.
  # Name: apim-wkld-shared-<env>  RG: rg-wkld-shared-<env>
  apim_name = "apim-${local.workload}-shared-${local.environment}"
  apim_rg   = local.env.resource_group_shared

  # ── Client certificate thumbprint ─────────────────────────────────────────
  # Read from phase1/core state where it is computed via the tls_certificate
  # data source (SHA-1 of the DER-encoded certificate).
  client_cert_thumbprint = upper(local.core.client_cert_thumbprint)

  # Sorted stamp keys — deterministic ordering for the load-balancing policy
  # and for deriving primary_stamp_key without a redundant sort call.
  sorted_stamp_keys = sort(keys(local.stamps_map))
  stamp_count       = length(local.stamps_map)

  # Primary stamp key (lowest numeric stamp) — used for the health-check
  # operation, which bypasses mTLS and always routes to a single backend.
  primary_stamp_key = local.sorted_stamp_keys[0]
}
