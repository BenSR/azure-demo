# ─── Application Gateway ──────────────────────────────────────────────────────

output "appgw_hostname" {
  value       = "${azurerm_private_dns_a_record.appgw.name}.${azurerm_private_dns_a_record.appgw.zone_name}"
  description = "Private DNS hostname for the Application Gateway PE.  Use this to call the API: https://<hostname>/api/<env>/<operation>"
}

output "appgw_private_endpoint_ip" {
  value       = azurerm_private_endpoint.appgw.private_service_connection[0].private_ip_address
  description = "Private IP address of the Application Gateway Private Endpoint (in snet-shared-pe)."
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
      health  = "https://appgw.internal.contoso.com/api/${env}/health"
      message = "https://appgw.internal.contoso.com/api/${env}/message"
    }
  }
  description = "API URLs per environment through the Application Gateway PE.  Clients must present a valid mTLS client certificate.  Only resolvable from within the VNet."
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
