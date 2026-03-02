# ─── Private DNS Module — Unit Tests ──────────────────────────────────────────
# Uses mock providers so no Azure credentials are required.
# Run: terraform -chdir=terraform/modules/private-dns test

mock_provider "azurerm" {}

variables {
  resource_group_name = "rg-core-dev"
}

# ─── Zone count ───────────────────────────────────────────────────────────────

run "eight_dns_zones_created" {
  command = apply

  assert {
    condition     = length(output.all_zone_ids) == 8
    error_message = "Expected exactly 8 Private DNS Zones (Key Vault, Blob, File, Table, Queue, ACR, Websites, APIM)"
  }
}

# ─── Service-specific zone names ──────────────────────────────────────────────

run "key_vault_and_compute_zones" {
  command = apply

  assert {
    condition     = azurerm_private_dns_zone.key_vault.name == "privatelink.vaultcore.azure.net"
    error_message = "Key Vault DNS zone name must be privatelink.vaultcore.azure.net"
  }

  assert {
    condition     = azurerm_private_dns_zone.acr.name == "privatelink.azurecr.io"
    error_message = "ACR DNS zone name must be privatelink.azurecr.io"
  }

  assert {
    condition     = azurerm_private_dns_zone.websites.name == "privatelink.azurewebsites.net"
    error_message = "Websites DNS zone name must be privatelink.azurewebsites.net"
  }

  assert {
    condition     = azurerm_private_dns_zone.apim.name == "internal.contoso.com"
    error_message = "APIM DNS zone name must be internal.contoso.com"
  }
}

run "storage_zones" {
  command = apply

  assert {
    condition     = azurerm_private_dns_zone.blob_storage.name == "privatelink.blob.core.windows.net"
    error_message = "Blob storage DNS zone name must be privatelink.blob.core.windows.net"
  }

  assert {
    condition     = azurerm_private_dns_zone.file_storage.name == "privatelink.file.core.windows.net"
    error_message = "File storage DNS zone name must be privatelink.file.core.windows.net"
  }

  assert {
    condition     = azurerm_private_dns_zone.table_storage.name == "privatelink.table.core.windows.net"
    error_message = "Table storage DNS zone name must be privatelink.table.core.windows.net"
  }

  assert {
    condition     = azurerm_private_dns_zone.queue_storage.name == "privatelink.queue.core.windows.net"
    error_message = "Queue storage DNS zone name must be privatelink.queue.core.windows.net"
  }
}

# ─── All zones in the same resource group ─────────────────────────────────────

run "all_zones_in_correct_resource_group" {
  command = apply

  assert {
    condition     = azurerm_private_dns_zone.key_vault.resource_group_name == "rg-core-dev"
    error_message = "Key Vault zone must be in the specified resource group"
  }

  assert {
    condition     = azurerm_private_dns_zone.blob_storage.resource_group_name == "rg-core-dev"
    error_message = "Blob storage zone must be in the specified resource group"
  }

  assert {
    condition     = azurerm_private_dns_zone.apim.resource_group_name == "rg-core-dev"
    error_message = "APIM zone must be in the specified resource group"
  }
}

# ─── Individual outputs expose correct zone IDs ───────────────────────────────

run "individual_zone_outputs_non_null" {
  command = apply

  assert {
    condition     = output.key_vault_zone_id != null
    error_message = "key_vault_zone_id output must not be null"
  }

  assert {
    condition     = output.blob_storage_zone_id != null
    error_message = "blob_storage_zone_id output must not be null"
  }

  assert {
    condition     = output.acr_zone_id != null
    error_message = "acr_zone_id output must not be null"
  }

  assert {
    condition     = output.apim_zone_id != null
    error_message = "apim_zone_id output must not be null"
  }
}
