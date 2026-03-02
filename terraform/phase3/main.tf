# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — Application Gateway (public ingress to APIM)
#
# This root module deploys a shared Application Gateway v2 that provides
# public HTTPS+mTLS ingress to both dev and prod APIM instances.  It is NOT
# workspace-driven — the gateway routes to all configured environments
# simultaneously via URL path-based routing:
#
#   https://<appgw-pip>/api/dev/message  → APIM dev  → Function App (dev)
#   https://<appgw-pip>/api/prod/health  → APIM prod → Function App (prod)
#
# Rewrite rules strip the environment segment before forwarding to APIM, so
# APIM receives requests at its existing API path (/api/<operation>).
#
# TLS termination (including mTLS client certificate validation) is handled
# at the Application Gateway — APIM no longer validates client certificates.
# The CA certificate generated in phase1/core is used as the mTLS truststore
# on the App Gateway.  A self-signed server certificate (generated in Key
# Vault) is presented to clients on the HTTPS listener.
#
# ── Prerequisites (changes to existing infrastructure) ────────────────────
#
# 1. phase2/env/apim-config.tf — Add "http" to the APIM API protocols:
#        protocols = ["https", "http"]
#    This allows the App Gateway to communicate with APIM over HTTP (port 80)
#    within the VNet.  Alternatively, configure APIM custom domain with a cert
#    signed by the CA and use HTTPS backend (recommended for production).
#
# 2. phase2/env/apim-config.tf — Remove <validate-client-certificate> from
#    the API-level policy.  mTLS is now terminated at the Application Gateway.
#    Keep the MI auth (<authentication-managed-identity>) unchanged.
#
# ── Deployment ────────────────────────────────────────────────────────────
#
# Phase 3 runs on the VNet-injected runner (snet-runner) so it can reach
# the Key Vault Private Endpoint for certificate provisioning.
#
#   terraform -chdir=terraform/phase3 init -backend-config=backend.hcl
#   terraform -chdir=terraform/phase3 apply
#
# ── Backend config example (backend.hcl) ──────────────────────────────────
#
#   resource_group_name  = "rg-core-deploy"
#   storage_account_name = "<your-state-storage-account>"
#   container_name       = "tfstate"
#   key                  = "phase3.tfstate"
#
# ═══════════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
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

# ─── Shared locals ────────────────────────────────────────────────────────────

locals {
  name_suffix = "core"

  tags = {
    layer      = "appgw"
    managed_by = "terraform"
    project    = "azure-demo"
    phase      = "3"
  }

  # Aliases for remote state outputs.
  core = data.terraform_remote_state.core.outputs

  # Per-environment APIM details from each env workspace's remote state.
  env = {
    for env_key, rs in data.terraform_remote_state.env : env_key => rs.outputs
  }

  # Extract APIM gateway hostnames (strip https:// prefix).
  # e.g. "apim-wkld-shared-dev.azure-api.net"
  env_apim_hostnames = {
    for env_key, env_data in local.env :
    env_key => trimprefix(env_data.apim_gateway_url, "https://")
  }
}

# ─── Data sources ─────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}

# ─── Remote state — phase1/core ───────────────────────────────────────────────

data "terraform_remote_state" "core" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-core-deploy"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "phase1-core.tfstate"
  }
}

# ─── Remote state — phase1/env (one per environment) ──────────────────────────
# Reads the APIM gateway URL and private IP from each environment workspace.

data "terraform_remote_state" "env" {
  for_each = toset(var.environments)
  backend  = "azurerm"

  config = {
    resource_group_name  = "rg-core-deploy"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "phase1-env.tfstate"
  }

  workspace = each.key
}
