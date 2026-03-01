# ─── API Management ───────────────────────────────────────────────────────────
# Developer tier in Internal VNet mode.
# Internal mode means the gateway is reachable only from within the VNet;
# there is no public endpoint.
#
# NOTE: The NSG rules required for APIM to provision (apim_in_allow_mgmt,
# apim_in_allow_lb_health, apim_in_allow_vnet_https) are applied by
# phase1/core and are guaranteed to exist before this root module runs.
# No depends_on is needed here.

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

# ─── APIM — diagnostic settings ───────────────────────────────────────────────
# Import block handles the case where the diagnostic setting was created
# outside of Terraform state (e.g. after a partial apply).  Safe to leave in
# place — once the resource is in state this block is a no-op.
import {
  to = azurerm_monitor_diagnostic_setting.apim
  id = "${azurerm_api_management.this.id}|diag-apim-${local.name_suffix}"
}

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
