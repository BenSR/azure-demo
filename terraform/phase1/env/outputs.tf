# ─── Workspace / environment ──────────────────────────────────────────────────

output "environment" {
  value       = local.environment
  description = "Effective environment name derived from the active Terraform workspace."
}

# ─── APIM ────────────────────────────────────────────────────────────────────

output "apim_gateway_url" {
  value       = azurerm_api_management.this.gateway_url
  description = "APIM internal gateway URL. Reachable only from within the VNet."
}

output "apim_private_ip" {
  value       = tolist(azurerm_api_management.this.private_ip_addresses)[0]
  description = "APIM private IP address within the VNet."
}

output "apim_id" {
  value       = azurerm_api_management.this.id
  description = "APIM resource ID."
}

# ─── Workload stamps ──────────────────────────────────────────────────────────
# Each output is a map keyed by stamp number (e.g. "1", "2").

output "function_app_hostnames" {
  value = {
    for stamp_key, stamp_module in module.workload_stamp :
    stamp_key => stamp_module.function_app_hostnames
  }
  description = "Map of stamp number → (map of Function App name → default hostname)."
}

output "storage_account_names" {
  value = {
    for stamp_key, stamp_module in module.workload_stamp :
    stamp_key => stamp_module.storage_account_name
  }
  description = "Map of stamp number → Storage Account name."
}

output "key_vault_uris" {
  value = {
    for stamp_key, stamp_module in module.workload_stamp :
    stamp_key => stamp_module.key_vault_uri
  }
  description = "Map of stamp number → Key Vault URI."
}

output "key_vault_ids" {
  value = {
    for stamp_key, stamp_module in module.workload_stamp :
    stamp_key => stamp_module.key_vault_id
  }
  description = "Map of stamp number → Key Vault resource ID. Used by Phase 3 to write secrets and certificates."
}

output "app_insights_ids" {
  value = {
    for stamp_key, stamp_module in module.workload_stamp :
    stamp_key => stamp_module.app_insights_id
  }
  description = "Map of stamp number → Application Insights resource ID. Used by Phase 3 alert rules."
}

output "entra_client_ids" {
  value = {
    for stamp_key, app in azuread_application.func_api :
    stamp_key => app.client_id
  }
  description = "Map of stamp number → Entra app registration client ID. Used by Phase 3 to construct the APIM managed-identity auth resource URI."
}

output "function_app_webhook_urls" {
  value = {
    for stamp_key, stamp_module in module.workload_stamp :
    stamp_key => stamp_module.function_app_webhook_urls
  }
  description = "Map of stamp number → (map of Function App name → Kudu deployment webhook URL). Read by Phase 3 and written to Key Vault so the CI/CD runner can trigger image pulls."
  sensitive   = true
}

# ─── Resource groups ──────────────────────────────────────────────────────────

output "resource_group_shared" {
  value       = azurerm_resource_group.shared.name
  description = "Per-environment shared resource group name (APIM)."
}

output "resource_group_stamps" {
  value = {
    for stamp_key, rg in azurerm_resource_group.stamp :
    stamp_key => rg.name
  }
  description = "Map of stamp number → resource group name (ASP, Function App, Storage, App Insights, Key Vault)."
}
