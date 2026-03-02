# ─── ACR — AcrPull ───────────────────────────────────────────────────────────
# Allows each Function App to pull its container image from ACR without
# storing registry credentials anywhere.

resource "azurerm_role_assignment" "acr_pull" {
  for_each = var.function_apps

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_function_app.this[each.key].identity[0].principal_id
}

# ─── Key Vault — Function App access ─────────────────────────────────────────
# Allows each Function App to read secrets and certificates from this stamp's KV.

resource "azurerm_role_assignment" "kv_secrets_user" {
  for_each = var.function_apps

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.this[each.key].identity[0].principal_id
}

# ─── Key Vault — CI/CD SP access ──────────────────────────────────────────────
# The Terraform caller (CI/CD SP) needs Key Vault Administrator on the data
# plane so that Phase 3 (running on the self-hosted VNet runner) can import
# certificates and write secrets into this stamp's KV.

resource "azurerm_role_assignment" "kv_admin_cicd" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ─── Key Vault — Admin user access ────────────────────────────────────────────
# Allows the admin user to read and manage secrets in the stamp KV via the
# Azure portal or CLI (e.g. for troubleshooting from the jumpbox).

resource "azurerm_role_assignment" "kv_secrets_officer_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azuread_user.admin.object_id
}

# ─── Key Vault — APIM access ───────────────────────────────────────────────────
# In Phase 3, APIM will load the CA certificate from this stamp's KV for mTLS
# client certificate validation.  Pre-assign both roles so Phase 3 can
# reference the cert immediately.

resource "azurerm_role_assignment" "kv_cert_user_apim" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Certificate User"
  principal_id         = var.apim_principal_id
}

resource "azurerm_role_assignment" "kv_secrets_user_apim" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.apim_principal_id
}

# ─── Storage — data-plane roles ───────────────────────────────────────────────
# Required for storage_uses_managed_identity = true on the Function App.
# The Function App platform uses blob, queue, and table for trigger state,
# leases, and host coordination.

resource "azurerm_role_assignment" "storage_blob_owner" {
  for_each = var.function_apps

  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_linux_function_app.this[each.key].identity[0].principal_id
}

resource "azurerm_role_assignment" "storage_queue_contributor" {
  for_each = var.function_apps

  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_linux_function_app.this[each.key].identity[0].principal_id
}

resource "azurerm_role_assignment" "storage_table_contributor" {
  for_each = var.function_apps

  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_linux_function_app.this[each.key].identity[0].principal_id
}
