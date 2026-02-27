# ─── Resource Groups ──────────────────────────────────────────────────────────
#
# PREREQUISITE — rg-core-deploy  (NOT managed here)
# A deployment resource group for Terraform state storage must be created
# manually before running `terraform init`.  It is intentionally outside this
# configuration to avoid the chicken-and-egg problem.
#   az group create --name rg-core-deploy --location <location>
#
# ─────────────────────────────────────────────────────────────────────────────

# Core platform infra — VNet, ACR, Log Analytics, NAT GW, DNS, Jump Box.
# Deployed once; shared across all environments.
# Naming: rg-core

resource "azurerm_resource_group" "core" {
  name     = "rg-${local.name_suffix}"
  location = var.location
  tags     = local.tags
}
