# ─── Entra ID ────────────────────────────────────────────────────────────────
data "azuread_client_config" "current" {}

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
  backend   = "azurerm"
  workspace = terraform.workspace

  config = {
    resource_group_name  = "rg-core-deploy"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "phase1-env.tfstate"
  }
}

# ─── Application Insights — per stamp ────────────────────────────────────────
# Looked up to read the exact location of each App Insights instance.
# Standard web tests must be created in the same location as their linked
# component — which may differ from var.location when stamps span regions.

data "azurerm_application_insights" "stamps" {
  for_each            = local.stamps_map
  name                = "appi-wkld-${each.key}-${local.environment}"
  resource_group_name = local.env.resource_group_stamps[each.key]
}
