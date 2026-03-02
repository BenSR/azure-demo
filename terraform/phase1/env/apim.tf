# ─── API Management ───────────────────────────────────────────────────────────
# Developer tier in Internal VNet mode.
# Internal mode means the gateway is reachable only from within the VNet;
# there is no public endpoint.
#
# NOTE: The NSG rules required for APIM to provision (apim_in_allow_mgmt,
# apim_in_allow_lb_health, apim_in_allow_vnet_https) are applied by
# phase1/core and are guaranteed to exist before this root module runs.

resource "azurerm_api_management" "this" {
  name                = "apim-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.location
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email

  sku_name = "Developer_1"

  # Internal VNet mode — APIM is not reachable from the public internet.
  virtual_network_type = "Internal"

  virtual_network_configuration {
    subnet_id = local.core.subnet_ids["snet-apim"]
  }

  # System-assigned MI used in Phase 3 to retrieve mTLS certs from Key Vault.
  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# ─── APIM — Private DNS A record ──────────────────────────────────────────────
# Internal VNet mode APIM does not create a Private Endpoint.

resource "azurerm_private_dns_a_record" "apim_gateway" {
  name                = azurerm_api_management.this.name
  zone_name           = "azure-api.net"
  resource_group_name = local.core.resource_group_core
  ttl                 = 300
  records             = [tolist(azurerm_api_management.this.private_ip_addresses)[0]]
}

# ─── APIM — diagnostic settings ───────────────────────────────────────────────
resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "diag-apim-${local.name_suffix}"
  target_resource_id         = azurerm_api_management.this.id
  log_analytics_workspace_id = local.core.log_analytics_workspace_id

  enabled_log {
    category = "GatewayLogs"
  }

  enabled_log {
    category = "WebSocketConnectionLogs"
  }
}
