terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.50"
    }
  }

  # Backend config is supplied at init time via -backend-config flags or a
  # backend.hcl file so that secrets never appear in source control.
  #
  # Example backend.hcl:
  #   resource_group_name  = "rg-core-deploy"
  #   storage_account_name = "<your-state-storage-account>"
  #   container_name       = "tfstate"
  #   key                  = "phase1-env.tfstate"
  #
  # Example init command:
  #   terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}

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
