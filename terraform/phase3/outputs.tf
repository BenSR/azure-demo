# ─── Application Gateway ──────────────────────────────────────────────────────

output "appgw_public_ip" {
  value       = azurerm_public_ip.appgw.ip_address
  description = "Public IP address of the Application Gateway.  Use this to call the API: https://<ip>/api/<env>/<operation>"
}

output "appgw_id" {
  value       = azurerm_application_gateway.this.id
  description = "Application Gateway resource ID."
}

output "appgw_name" {
  value       = azurerm_application_gateway.this.name
  description = "Application Gateway name."
}

# ─── URL path examples ────────────────────────────────────────────────────────

output "api_urls" {
  value = {
    for env in var.environments : env => {
      health  = "https://${azurerm_public_ip.appgw.ip_address}/api/${env}/health"
      message = "https://${azurerm_public_ip.appgw.ip_address}/api/${env}/message"
    }
  }
  description = "API URLs per environment through the Application Gateway.  Clients must present a valid mTLS client certificate."
}

# ─── Key Vault ────────────────────────────────────────────────────────────────

output "key_vault_id" {
  value       = azurerm_key_vault.appgw.id
  description = "App Gateway Key Vault resource ID."
}

output "server_cert_secret_id" {
  value       = azurerm_key_vault_certificate.server.versionless_secret_id
  description = "Key Vault secret ID (versionless) for the App Gateway TLS server certificate."
}
