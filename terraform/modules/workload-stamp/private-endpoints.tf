locals {
  # Storage sub-resource → DNS zone ID mapping.
  storage_subresources = {
    blob  = var.private_dns_zone_ids.blob_storage_zone_id
    file  = var.private_dns_zone_ids.file_storage_zone_id
    table = var.private_dns_zone_ids.table_storage_zone_id
    queue = var.private_dns_zone_ids.queue_storage_zone_id
  }
}

# ─── Storage Account — Private Endpoints ─────────────────────────────────────
# One PE per sub-resource (blob, file, table, queue), all placed in the stamp
# PE subnet with DNS zone group registration.

resource "azurerm_private_endpoint" "storage" {
  for_each = local.storage_subresources

  name                = "pe-st${local.stamp_prefix_clean}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-st${local.stamp_prefix_clean}-${each.key}"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dzg-${each.key}"
    private_dns_zone_ids = [each.value]
  }

  tags = var.tags
}

# ─── Function App — Private Endpoint ─────────────────────────────────────────
# One PE per Function App, enabling inbound HTTPS traffic from APIM via the
# private backbone without a public endpoint.

resource "azurerm_private_endpoint" "function_app" {
  for_each = var.function_apps

  name                = "pe-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = azurerm_linux_function_app.this[each.key].id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dzg-websites"
    private_dns_zone_ids = [var.private_dns_zone_ids.websites_zone_id]
  }

  tags = var.tags
}
