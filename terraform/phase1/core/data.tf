# ─── CI/CD Service Principal ──────────────────────────────────────────────────
#
# The CI/CD service principal (with Owner access on the subscription) is
# created outside of Terraform.  Its identity is resolved at plan time via
# the azurerm_client_config data source (the SP that runs Terraform IS the
# CI/CD SP).  The object_id is passed in as a variable because env/ needs it
# for Key Vault Administrator role assignment.
#
# GitHub Actions secrets required:
#   ARM_CLIENT_ID       = (auto-detected)
#   ARM_TENANT_ID       = (auto-detected via OIDC)
#   ARM_SUBSCRIPTION_ID = var.subscription_id

data "azurerm_client_config" "current" {}

# ─── VM Administrator Lookup ─────────────────────────────────────────────────
# Resolves the Entra ID user for runner VM admin login RBAC.

data "azuread_user" "runner_admin" {
  user_principal_name = var.runner_admin_upn
}
