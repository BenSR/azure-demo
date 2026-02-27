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
  #   key                  = "phase3.tfstate"
  #
  # Phase 3 is workspace-driven (dev/prod).  Use the same workspace as
  # the phase1/env deployment it targets:
  #
  #   terraform -chdir=terraform/phase3 workspace select dev
  #   terraform -chdir=terraform/phase3 apply \
  #     -var-file=terraform.tfvars -var-file=dev.tfvars
  #
  # Phase 3 MUST run from a VNet-injected runner (snet-runner subnet) so it
  # can reach Key Vault and APIM Private Endpoints.
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
  # workspace used when applying phase1/env/ so that remote state resolves.
  environment = terraform.workspace == "default" ? "dev" : terraform.workspace

  tags = {
    workload    = local.workload
    environment = local.environment
    workspace   = terraform.workspace
    managed_by  = "terraform"
    project     = "azure-demo"
    phase       = "3"
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
  # Computed from the client certificate PEM stored in phase1/core state.
  # Strips the PEM header/footer, decodes the base64 DER body, and produces
  # the SHA-1 fingerprint that APIM uses to validate incoming client certs.
  _client_cert_b64 = replace(
    replace(
      replace(trimspace(local.core.client_cert_pem),
        "-----BEGIN CERTIFICATE-----", ""),
      "-----END CERTIFICATE-----", ""),
    "\n", "")

  client_cert_thumbprint = upper(sha1(base64decode(local._client_cert_b64)))

  # Primary stamp key (lowest numeric stamp) — default backend for the API
  # policy.  Extend with a backend pool or routing header for multi-stamp.
  primary_stamp_key = tolist(sort(keys(local.stamps_map)))[0]
}

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
