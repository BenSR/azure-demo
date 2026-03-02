# ─── Workspace / environment ──────────────────────────────────────────────────

output "environment" {
  value       = local.environment
  description = "Effective environment name derived from the active Terraform workspace."
}

# ─── APIM ────────────────────────────────────────────────────────────────────

output "apim_gateway_url" {
  value       = local.env.apim_gateway_url
  description = "APIM internal gateway URL. Reachable only from within the VNet."
}

output "api_id" {
  value       = azurerm_api_management_api.wkld.id
  description = "Workload API resource ID in APIM."
}

output "debug_api_policy_xml" {
  value       = local._debug_api_policy_xml
  description = "DEBUG: Computed API policy XML for troubleshooting."
}

output "api_path" {
  value       = "https://${trimprefix(local.env.apim_gateway_url, "https://")}/${azurerm_api_management_api.wkld.path}"
  description = "Full APIM URL prefix for the workload API (append the operation url_template to call an operation)."
}

output "backend_ids" {
  value = {
    for stamp_key, backend in azurerm_api_management_backend.func :
    stamp_key => backend.id
  }
  description = "Map of stamp number → APIM backend resource ID."
}

# ─── Certificates ─────────────────────────────────────────────────────────────

output "client_cert_thumbprint" {
  value       = local.client_cert_thumbprint
  description = "SHA-1 thumbprint of the client certificate used for mTLS. Callers must present a certificate matching this thumbprint."
}

output "ca_cert_secret_ids" {
  value = {
    for stamp_key, secret in azurerm_key_vault_secret.ca_cert :
    stamp_key => secret.id
  }
  description = "Map of stamp number → Key Vault secret ID for the CA certificate PEM."
}

output "client_cert_secret_ids" {
  value = {
    for stamp_key, secret in azurerm_key_vault_secret.client_cert :
    stamp_key => secret.id
  }
  description = "Map of stamp number → Key Vault secret ID for the client certificate PEM."
}

# ─── Alerts ───────────────────────────────────────────────────────────────────

output "action_group_id" {
  value       = azurerm_monitor_action_group.wkld.id
  description = "Monitor Action Group resource ID for the environment."
}

output "failure_alert_ids" {
  value = {
    for stamp_key, alert in azurerm_monitor_metric_alert.func_failures :
    stamp_key => alert.id
  }
  description = "Map of stamp number → request failure alert rule resource ID."
}

output "availability_alert_ids" {
  value = {
    for stamp_key, alert in azurerm_monitor_metric_alert.func_availability :
    stamp_key => alert.id
  }
  description = "Map of stamp number → availability alert rule resource ID."
}

output "query_5xx_alert_ids" {
  value = {
    for stamp_key, alert in azurerm_monitor_scheduled_query_rules_alert_v2.func_5xx_query :
    stamp_key => alert.id
  }
  description = "Map of stamp number → scheduled query rule alert resource ID (HTTP 5xx direct query)."
}
