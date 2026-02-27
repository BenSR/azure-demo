# ═══════════════════════════════════════════════════════════════════════════════
# NSG Rules — per-stamp subnet rules + cross-cutting rules on shared NSGs
#
# Per-stamp rules are attached to the stamp's own PE and ASP NSGs.
# Cross-cutting rules are attached to the *shared* NSGs (apim, shared-pe,
# runner, jumpbox) so that traffic can flow between shared and stamp subnets.
# Priorities on shared NSGs use var.stamp_index to avoid collisions across
# stamps.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── snet-stamp-<N>-pe  (Private Endpoints) ──────────────────────────────────
# PEs are passive — they only accept inbound connections; deny all outbound.

resource "azurerm_network_security_rule" "pe_in_allow_apim" {
  name                        = "allow-inbound-apim"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.shared_subnet_cidrs.apim
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe.name
}

resource "azurerm_network_security_rule" "pe_in_allow_asp" {
  name                        = "allow-inbound-asp"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.subnet_asp_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe.name
}

resource "azurerm_network_security_rule" "pe_in_allow_runner" {
  name                        = "allow-inbound-runner"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.shared_subnet_cidrs.runner
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe.name
}

resource "azurerm_network_security_rule" "pe_in_allow_jumpbox" {
  name                        = "allow-inbound-jumpbox"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.shared_subnet_cidrs.jumpbox
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe.name
}

resource "azurerm_network_security_rule" "pe_out_deny_all" {
  name                        = "deny-all-outbound"
  priority                    = 4000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.pe.name
}

# ─── snet-stamp-<N>-asp  (App Service Plan VNet integration) ──────────────────

resource "azurerm_network_security_rule" "asp_in_allow_lb" {
  name                        = "allow-inbound-azure-lb"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.asp.name
}

resource "azurerm_network_security_rule" "asp_out_allow_stamp_pe" {
  name                        = "allow-outbound-stamp-pe"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = var.subnet_pe_cidr
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.asp.name
}

resource "azurerm_network_security_rule" "asp_out_allow_shared_pe" {
  name                        = "allow-outbound-shared-pe"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = var.shared_subnet_cidrs.shared_pe
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.asp.name
}

resource "azurerm_network_security_rule" "asp_out_allow_monitor" {
  name                        = "allow-outbound-azure-monitor"
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "AzureMonitor"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.asp.name
}

resource "azurerm_network_security_rule" "asp_out_allow_dns" {
  name                        = "allow-outbound-dns"
  priority                    = 130
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.asp.name
}

resource "azurerm_network_security_rule" "asp_out_deny_internet" {
  name                        = "deny-outbound-internet"
  priority                    = 4000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.asp.name
}

# ═══════════════════════════════════════════════════════════════════════════════
# Cross-cutting rules on shared NSGs
#
# These rules are attached to the *caller-provided* shared NSGs so that
# traffic can flow between shared infrastructure subnets and this stamp's
# subnets.  Priorities are offset by var.stamp_index to avoid collisions
# when multiple stamps each add a rule to the same shared NSG.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── snet-apim → stamp PE (outbound 443) ─────────────────────────────────────

resource "azurerm_network_security_rule" "shared_apim_out_allow_stamp_pe" {
  name                        = "allow-outbound-stamp-${local.stamp_id}-pe"
  priority                    = 100 + var.stamp_index
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = var.subnet_pe_cidr
  resource_group_name         = var.resource_group_name
  network_security_group_name = var.shared_nsg_names.apim
}

# ─── snet-shared-pe ← stamp ASP (inbound 443) ────────────────────────────────

resource "azurerm_network_security_rule" "shared_pe_in_allow_stamp_asp" {
  name                        = "allow-inbound-stamp-${local.stamp_id}-asp"
  priority                    = 100 + var.stamp_index
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.subnet_asp_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = var.shared_nsg_names.shared_pe
}

# ─── snet-runner → stamp PE (outbound 443) ────────────────────────────────────

resource "azurerm_network_security_rule" "shared_runner_out_allow_stamp_pe" {
  name                        = "allow-outbound-stamp-${local.stamp_id}-pe"
  priority                    = 100 + var.stamp_index
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = var.subnet_pe_cidr
  resource_group_name         = var.resource_group_name
  network_security_group_name = var.shared_nsg_names.runner
}

# ─── snet-jumpbox → stamp PE (outbound 443) ──────────────────────────────────

resource "azurerm_network_security_rule" "shared_jumpbox_out_allow_stamp_pe" {
  name                        = "allow-outbound-stamp-${local.stamp_id}-pe"
  priority                    = 100 + var.stamp_index
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = var.subnet_pe_cidr
  resource_group_name         = var.resource_group_name
  network_security_group_name = var.shared_nsg_names.jumpbox
}
