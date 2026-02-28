# ─── Shared locals ────────────────────────────────────────────────────────────

locals {
  workload = "wkld"

  # Environment is driven by the Terraform workspace name — must match the
  # workspace used when applying phase1/core/ so that remote state is resolved
  # correctly.
  environment = terraform.workspace == "default" ? "dev" : terraform.workspace

  name_suffix = "${local.workload}-shared-${local.environment}"

  tags = {
    workload    = local.workload
    environment = local.environment
    workspace   = terraform.workspace
    managed_by  = "terraform"
    project     = "azure-demo"
  }

  # Alias for core outputs — keeps resource definitions readable.
  core = data.terraform_remote_state.core.outputs
}
