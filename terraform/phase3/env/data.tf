# ─── Remote state — phase1/core ───────────────────────────────────────────────
# Core is deployed once (not workspace-scoped); state key is always the same.

data "terraform_remote_state" "core" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-core-deploy"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "phase1-core.tfstate"
  }
}

# ─── Remote state — phase1/env ────────────────────────────────────────────────
# Workspace-scoped — the key path matches the workspace used by phase1/env.
# Phase 3 must run in the same workspace as the phase1/env deployment it
# targets (e.g. workspace "dev" reads the dev APIM, stamps, and KV outputs).

data "terraform_remote_state" "env" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-core-deploy"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "env:/${terraform.workspace}/phase1-env.tfstate"
  }
}
