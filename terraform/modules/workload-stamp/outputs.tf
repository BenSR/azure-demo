output "app_service_plan_id" {
  value       = azurerm_service_plan.this.id
  description = "App Service Plan resource ID."
}

output "function_app_ids" {
  value       = { for k, v in azurerm_linux_function_app.this : k => v.id }
  description = "Map of Function App name → resource ID."
}

output "function_app_identities" {
  value = {
    for k, v in azurerm_linux_function_app.this : k => {
      principal_id = v.identity[0].principal_id
      tenant_id    = v.identity[0].tenant_id
    }
  }
  description = "Map of Function App name → managed identity (principal_id, tenant_id)."
}

output "function_app_hostnames" {
  value       = { for k, v in azurerm_linux_function_app.this : k => v.default_hostname }
  description = "Map of Function App name → default hostname."
}

output "storage_account_id" {
  value       = azurerm_storage_account.this.id
  description = "Stamp Storage Account resource ID."
}

output "storage_account_name" {
  value       = azurerm_storage_account.this.name
  description = "Stamp Storage Account name."
}

output "app_insights_instrumentation_key" {
  value       = azurerm_application_insights.this.instrumentation_key
  description = "Application Insights instrumentation key."
  sensitive   = true
}

output "app_insights_connection_string" {
  value       = azurerm_application_insights.this.connection_string
  description = "Application Insights connection string."
  sensitive   = true
}

output "app_insights_id" {
  value       = azurerm_application_insights.this.id
  description = "Application Insights resource ID."
}

output "key_vault_id" {
  value       = azurerm_key_vault.this.id
  description = "Stamp Key Vault resource ID. Used by Phase 3 to write secrets and certificates."
}

output "key_vault_uri" {
  value       = azurerm_key_vault.this.vault_uri
  description = "Stamp Key Vault URI."
}

output "function_app_webhook_urls" {
  value = {
    for k, v in azurerm_linux_function_app.this : k =>
    "https://${v.site_credential[0].name}:${v.site_credential[0].password}@${k}.scm.azurewebsites.net/api/registry/webhook"
  }
  description = "Map of Function App name → Kudu container deployment webhook URL. CI/CD POSTs to this URL (retrieved from Key Vault) to trigger an image pull and restart without a Terraform apply."
  sensitive   = true
}
