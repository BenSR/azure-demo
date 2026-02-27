# ─── Identity — CI/CD service principal ──────────────────────────────────────

output "cicd_client_id" {
  value       = data.azurerm_client_config.current.client_id
  description = "Client (application) ID of the CI/CD service principal (auto-detected from the authenticated session)."
}

output "cicd_object_id" {
  value       = var.cicd_object_id
  description = "Object ID of the CI/CD service principal. Used by env/ to assign Key Vault Administrator role."
}

# ─── ACR ─────────────────────────────────────────────────────────────────────

output "acr_login_server" {
  value       = azurerm_container_registry.this.login_server
  description = "ACR login server URL (e.g. acrcore.azurecr.io). Used in Phase 3 to push images."
}

output "acr_id" {
  value       = azurerm_container_registry.this.id
  description = "ACR resource ID. Used by env/ workload-stamp modules for AcrPull role assignment."
}

# ─── Networking ───────────────────────────────────────────────────────────────

output "vnet_id" {
  value       = module.vnet.vnet_id
  description = "VNet resource ID."
}

output "subnet_ids" {
  value = merge(
    module.vnet.subnet_ids,
    { for k, v in module.workload_stamp_subnet : "snet-stamp-${k}-pe" => v.pe_subnet_id },
    { for k, v in module.workload_stamp_subnet : "snet-stamp-${k}-asp" => v.asp_subnet_id },
  )
  description = "Map of subnet name → subnet resource ID. Keys include env-qualified stamps (e.g. snet-stamp-dev-1-pe). Consumed by env/ for APIM, KV PEs, and stamp subnets."
}

output "nat_gateway_public_ip" {
  value       = azurerm_public_ip.nat.ip_address
  description = "Public IP address of the NAT Gateway (runner egress)."
}

# ─── Observability ────────────────────────────────────────────────────────────

output "log_analytics_workspace_id" {
  value       = azurerm_log_analytics_workspace.this.id
  description = "Log Analytics Workspace resource ID. Consumed by env/ for all diagnostic settings."
}

# ─── Private DNS Zone IDs ─────────────────────────────────────────────────────
# Passed to env/ so workload-stamp modules and APIM/KV private endpoints can
# register their DNS records in the correct zones.

output "private_dns_zone_ids" {
  value = {
    blob_storage_zone_id  = module.private_dns.blob_storage_zone_id
    file_storage_zone_id  = module.private_dns.file_storage_zone_id
    table_storage_zone_id = module.private_dns.table_storage_zone_id
    queue_storage_zone_id = module.private_dns.queue_storage_zone_id
    websites_zone_id      = module.private_dns.websites_zone_id
    key_vault_zone_id     = module.private_dns.key_vault_zone_id
    acr_zone_id           = module.private_dns.acr_zone_id
  }
  description = "All Private DNS Zone IDs. Consumed by env/ for KV, stamp storage, and Function App private endpoints."
}

# ─── Certificates (sensitive — stored in Terraform state) ─────────────────────

output "ca_cert_pem" {
  value       = tls_self_signed_cert.ca.cert_pem
  sensitive   = true
  description = "Self-signed CA certificate in PEM format. Read by Phase 3 to upload to APIM for mTLS validation."
}

output "client_cert_pem" {
  value       = tls_locally_signed_cert.client.cert_pem
  sensitive   = true
  description = "Client certificate (signed by CA) in PEM format. Read by Phase 3 to write into Key Vault."
}

output "client_private_key_pem" {
  value       = tls_private_key.client.private_key_pem
  sensitive   = true
  description = "Client certificate private key in PEM format. Read by Phase 3 to write into Key Vault."
}

# ─── Resource groups ──────────────────────────────────────────────────────────

output "resource_group_core" {
  value       = azurerm_resource_group.core.name
  description = "Core resource group name (VNet, ACR, Log Analytics, DNS, Jump Box)."
}
