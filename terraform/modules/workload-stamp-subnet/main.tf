# ═══════════════════════════════════════════════════════════════════════════════
# workload-stamp-subnet — subnets, NSGs, and NSG rules for ONE workload stamp
#
# Creates a PE (Private Endpoints) subnet and an ASP (App Service Plan VNet
# integration) subnet, each with its own NSG and flow logs.  Also attaches
# cross-cutting NSG rules to the shared infrastructure NSGs (APIM, shared-pe,
# runner, jumpbox) so traffic can flow between shared and stamp subnets.
#
# Call this module once per stamp, passing environment, stamp_name, and
# stamp_index.
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  # Composite identifier used in all resource names: "<env>-<stamp_name>"
  stamp_id = "${var.environment}-${var.stamp_name}"

  pe_subnet_name  = "snet-stamp-${local.stamp_id}-pe"
  asp_subnet_name = "snet-stamp-${local.stamp_id}-asp"

  network_watcher_name = coalesce(var.network_watcher_name, "NetworkWatcher_${var.location}")

  flow_logs_enabled = (
    var.log_analytics_workspace_id != null &&
    var.log_analytics_workspace_guid != null &&
    var.flow_log_storage_account_id != null
  )
}

# ─── Subnets ──────────────────────────────────────────────────────────────────

resource "azurerm_subnet" "pe" {
  name                              = local.pe_subnet_name
  resource_group_name               = var.resource_group_name
  virtual_network_name              = var.vnet_name
  address_prefixes                  = [var.subnet_pe_cidr]
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_subnet" "asp" {
  name                 = local.asp_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = [var.subnet_asp_cidr]

  delegation {
    name = "delegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
    }
  }
}

# ─── Network Security Groups ──────────────────────────────────────────────────

resource "azurerm_network_security_group" "pe" {
  name                = "${var.nsg_name_prefix}-stamp-${local.stamp_id}-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_network_security_group" "asp" {
  name                = "${var.nsg_name_prefix}-stamp-${local.stamp_id}-asp"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# ─── NSG → Subnet associations ───────────────────────────────────────────────

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.pe.id
  network_security_group_id = azurerm_network_security_group.pe.id
}

resource "azurerm_subnet_network_security_group_association" "asp" {
  subnet_id                 = azurerm_subnet.asp.id
  network_security_group_id = azurerm_network_security_group.asp.id
}

# ─── NSG Flow Logs ────────────────────────────────────────────────────────────

resource "azurerm_network_watcher_flow_log" "pe" {
  count = local.flow_logs_enabled ? 1 : 0

  name                      = "fl-${var.nsg_name_prefix}-stamp-${local.stamp_id}-pe"
  network_watcher_name      = local.network_watcher_name
  resource_group_name       = var.network_watcher_resource_group_name
  network_security_group_id = azurerm_network_security_group.pe.id
  storage_account_id        = var.flow_log_storage_account_id
  enabled                   = true
  location                  = var.location
  tags                      = var.tags

  traffic_analytics {
    enabled               = true
    workspace_id          = var.log_analytics_workspace_guid
    workspace_region      = var.location
    workspace_resource_id = var.log_analytics_workspace_id
    interval_in_minutes   = 10
  }

  retention_policy {
    enabled = true
    days    = 7
  }
}

resource "azurerm_network_watcher_flow_log" "asp" {
  count = local.flow_logs_enabled ? 1 : 0

  name                      = "fl-${var.nsg_name_prefix}-stamp-${local.stamp_id}-asp"
  network_watcher_name      = local.network_watcher_name
  resource_group_name       = var.network_watcher_resource_group_name
  network_security_group_id = azurerm_network_security_group.asp.id
  storage_account_id        = var.flow_log_storage_account_id
  enabled                   = true
  location                  = var.location
  tags                      = var.tags

  traffic_analytics {
    enabled               = true
    workspace_id          = var.log_analytics_workspace_guid
    workspace_region      = var.location
    workspace_resource_id = var.log_analytics_workspace_id
    interval_in_minutes   = 10
  }

  retention_policy {
    enabled = true
    days    = 7
  }
}
