output "key_vault_zone_id" {
  value       = azurerm_private_dns_zone.key_vault.id
  description = "Zone ID for Key Vault private endpoints."
}

output "blob_storage_zone_id" {
  value       = azurerm_private_dns_zone.blob_storage.id
  description = "Zone ID for Blob Storage private endpoints."
}

output "file_storage_zone_id" {
  value       = azurerm_private_dns_zone.file_storage.id
  description = "Zone ID for File Storage private endpoints."
}

output "table_storage_zone_id" {
  value       = azurerm_private_dns_zone.table_storage.id
  description = "Zone ID for Table Storage private endpoints."
}

output "queue_storage_zone_id" {
  value       = azurerm_private_dns_zone.queue_storage.id
  description = "Zone ID for Queue Storage private endpoints."
}

output "acr_zone_id" {
  value       = azurerm_private_dns_zone.acr.id
  description = "Zone ID for ACR private endpoints."
}

output "websites_zone_id" {
  value       = azurerm_private_dns_zone.websites.id
  description = "Zone ID for Function App / Web App private endpoints."
}

output "apim_zone_id" {
  value       = azurerm_private_dns_zone.apim.id
  description = "Zone ID for API Management custom domain (internal.contoso.com) DNS resolution."
}

output "all_zone_ids" {
  value = [
    azurerm_private_dns_zone.key_vault.id,
    azurerm_private_dns_zone.blob_storage.id,
    azurerm_private_dns_zone.file_storage.id,
    azurerm_private_dns_zone.table_storage.id,
    azurerm_private_dns_zone.queue_storage.id,
    azurerm_private_dns_zone.acr.id,
    azurerm_private_dns_zone.websites.id,
    azurerm_private_dns_zone.apim.id,
  ]
  description = "All Private DNS Zone IDs — convenience list for bulk VNet linking."
}
