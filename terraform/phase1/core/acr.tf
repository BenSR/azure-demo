# ─── Azure Container Registry ─────────────────────────────────────────────────
# Premium SKU is required for Private Endpoint support.
# Deployed once; shared across all environments.
# Naming: acr<name_suffix><8-char subscription hex prefix>
#   e.g. acrcore09d0073b — globally unique per subscription, deterministic.

resource "azurerm_container_registry" "this" {
  name                = "acr${local.name_suffix}${substr(replace(data.azurerm_client_config.current.subscription_id, "-", ""), 0, 8)}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  sku                 = "Premium"
  admin_enabled       = false # Managed Identity auth only — no static credentials.

  # No public network access; all traffic is via the Private Endpoint.
  public_network_access_enabled = false
  network_rule_bypass_option    = "AzureServices"

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# ─── ACR — Private Endpoint ────────────────────────────────────────────────────
# Placed in the shared-PE subnet (snet-shared-pe) of this workspace's VNet.

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  subnet_id           = module.vnet.subnet_ids["snet-shared-pe"]

  private_service_connection {
    name                           = "psc-acr-${local.name_suffix}"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dzg-acr"
    private_dns_zone_ids = [module.private_dns.acr_zone_id]
  }

  tags = local.tags
}

