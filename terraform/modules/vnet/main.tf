locals {
  # Derive the NSG name prefix from the VNet name.
  # Convention: vnet-wkld-shared-dev  →  nsg-wkld-shared-dev
  nsg_name_prefix = replace(var.name, "vnet-", "nsg-")

  # Use the Azure-managed Network Watcher naming convention when not explicitly overridden.
  network_watcher_name = coalesce(var.network_watcher_name, "NetworkWatcher_${var.location}")

  # Flow logs require all three inputs to be present.
  flow_logs_enabled = (
    var.log_analytics_workspace_id != null &&
    var.log_analytics_workspace_guid != null &&
    var.flow_log_storage_account_id != null
  )
}

# ─── Virtual Network ──────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.address_space
  tags                = var.tags
}

# ─── Subnets ──────────────────────────────────────────────────────────────────

resource "azurerm_subnet" "this" {
  for_each = { for s in var.subnets : s.name => s }

  name                              = each.value.name
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = each.value.address_prefixes
  private_endpoint_network_policies = each.value.private_endpoint_network_policies
  service_endpoints                 = each.value.service_endpoints

  dynamic "delegation" {
    for_each = each.value.delegation != null ? [each.value.delegation] : []
    content {
      name = "delegation"
      service_delegation {
        name = delegation.value
      }
    }
  }
}

# ─── Network Security Groups ──────────────────────────────────────────────────
# One NSG per subnet.  Rules are intentionally empty here — the caller
# manages rules via azurerm_network_security_rule referencing module.vnet.nsg_ids.

resource "azurerm_network_security_group" "this" {
  for_each = { for s in var.subnets : s.name => s }

  # Strip the "snet-" prefix from the subnet name so the NSG name follows the
  # convention documented in the network technical design:
  #   snet-stamp-1-pe  →  nsg-wkld-shared-dev-stamp-1-pe
  name                = "${local.nsg_name_prefix}-${replace(each.value.name, "snet-", "")}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# ─── NSG → Subnet associations ───────────────────────────────────────────────

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = { for s in var.subnets : s.name => s }

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.key].id
}

# ─── NAT Gateway → Subnet associations ───────────────────────────────────────
# Only subnets with a nat_gateway_id set receive an association.

resource "azurerm_subnet_nat_gateway_association" "this" {
  for_each = {
    for s in var.subnets : s.name => s
    if s.nat_gateway_id != null
  }

  subnet_id      = azurerm_subnet.this[each.key].id
  nat_gateway_id = each.value.nat_gateway_id
}

# ─── Private DNS Zone VNet Links ─────────────────────────────────────────────
# Links every supplied zone ID to this VNet so all subnets resolve Private
# Endpoint FQDNs via Azure DNS (168.63.129.16).

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = toset(var.private_dns_zone_ids)

  # The zone name is the final segment of the resource ID.
  # Replace dots with dashes to produce a valid Azure resource name.
  name = "link-${azurerm_virtual_network.this.name}-${replace(
    element(split("/", each.value), length(split("/", each.value)) - 1),
    ".", "-"
  )}"

  resource_group_name   = var.resource_group_name
  private_dns_zone_name = element(split("/", each.value), length(split("/", each.value)) - 1)
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}

# ─── NSG Flow Logs ────────────────────────────────────────────────────────────
# Enabled for all NSGs when a Log Analytics Workspace and flow log storage
# account are provided.  Requires the Azure Network Watcher to exist in the
# region (Azure auto-creates NetworkWatcher_{location} in NetworkWatcherRG).

resource "azurerm_network_watcher_flow_log" "this" {
  for_each = local.flow_logs_enabled ? { for s in var.subnets : s.name => s } : {}

  name                      = "fl-${local.nsg_name_prefix}-${replace(each.value.name, "snet-", "")}"
  network_watcher_name      = local.network_watcher_name
  resource_group_name       = var.network_watcher_resource_group_name
  network_security_group_id = azurerm_network_security_group.this[each.key].id
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
