# ─── Key Vault client config ──────────────────────────────────────────────────
# Used to set the tenant_id on the Key Vault resource.

data "azurerm_client_config" "current" {}

# ─── Admin user ──────────────────────────────────────────────────────────────
# Looked up so we can assign Key Vault Secrets Officer on this stamp's KV.

data "azuread_user" "admin" {
  user_principal_name = var.admin_user_principal_name
}
