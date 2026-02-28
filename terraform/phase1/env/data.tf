# ─── Remote state — phase1/core ───────────────────────────────────────────────
# Reads the outputs of the core root module.  Core is deployed once (not
# workspace-based), so the state key is always "phase1-core.tfstate".

data "terraform_remote_state" "core" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-core-deploy"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "phase1-core.tfstate"
  }
}
