terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Backend config is supplied at init time via -backend-config flags or a
  # backend.hcl file so that secrets never appear in source control.
  #
  # Example backend.hcl:
  #   resource_group_name  = "rg-core-deploy"
  #   storage_account_name = "<your-state-storage-account>"
  #   container_name       = "tfstate"
  #   key                  = "phase1-core.tfstate"
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
      # Allow destroy even if resources remain (handy for teardown in assessment).
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "tls" {}

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
