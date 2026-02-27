# ─── Azure Container Registry ─────────────────────────────────────────────────
# Premium SKU is required for Private Endpoint support.
# Deployed once; shared across all environments.
# Naming: acrcore

resource "azurerm_container_registry" "this" {
  name                = "acrcore"
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

# ─── ACR — diagnostic settings ────────────────────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-acr-${local.name_suffix}"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }
}
