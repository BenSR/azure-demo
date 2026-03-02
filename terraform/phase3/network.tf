# ═══════════════════════════════════════════════════════════════════════════════
# Networking — App Gateway subnet, NSG, cross-cutting NSG rules
#
# The App Gateway subnet is created directly in the core VNet (outside the
# modules/vnet module) to avoid modifying phase1/core.  This is safe because
# the VNet module uses for_each over its own subnet list and will not attempt
# to manage subnets it does not know about.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── VNet data source ─────────────────────────────────────────────────────────

data "azurerm_virtual_network" "core" {
  name                = "vnet-core"
  resource_group_name = local.core.resource_group_core
}

# ─── App Gateway subnet ──────────────────────────────────────────────────────
# Application Gateway v2 requires a dedicated subnet with no other resources.
# No delegation needed.  No NAT Gateway — App GW has its own public IP.

resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = local.core.resource_group_core
  virtual_network_name = data.azurerm_virtual_network.core.name
  address_prefixes     = [var.appgw_subnet_cidr]
}

# ─── NSG: nsg-core-appgw ─────────────────────────────────────────────────────

resource "azurerm_network_security_group" "appgw" {
  name                = "nsg-core-appgw"
  resource_group_name = local.core.resource_group_core
  location            = var.location
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

# ── App GW subnet — Inbound rules ────────────────────────────────────────────

resource "azurerm_network_security_rule" "appgw_in_allow_gateway_manager" {
  # REQUIRED for Application Gateway v2 infrastructure health probes.
  # https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure#network-security-groups
  name                        = "allow-inbound-gateway-manager"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "GatewayManager"
  destination_address_prefix  = "*"
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_in_allow_https" {
  # Public HTTPS ingress — clients connect here with mTLS.
  name                        = "allow-inbound-https"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_in_allow_lb" {
  # REQUIRED for Azure Load Balancer health probes.
  name                        = "allow-inbound-azure-lb"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_in_deny_all" {
  name                        = "deny-all-inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = azurerm_network_security_group.appgw.name
}

# ── App GW subnet — Outbound rules ───────────────────────────────────────────

resource "azurerm_network_security_rule" "appgw_out_allow_apim_http" {
  # App GW → APIM backend over HTTP (port 80) within the VNet.
  # TLS is terminated at the App GW; backend traffic is plain HTTP.
  name                        = "allow-outbound-apim-http"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "*"
  destination_address_prefix  = "10.100.129.32/27" # snet-apim
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_out_allow_shared_pe" {
  # App GW → Key Vault PE (cert reads at runtime for auto-renewal).
  name                        = "allow-outbound-shared-pe"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "10.100.130.0/24" # snet-shared-pe
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_out_allow_internet" {
  # App GW platform dependencies (CRL checks, Azure Monitor, etc.).
  name                        = "allow-outbound-internet-https"
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = azurerm_network_security_group.appgw.name
}

resource "azurerm_network_security_rule" "appgw_out_allow_dns" {
  name                        = "allow-outbound-dns"
  priority                    = 130
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = azurerm_network_security_group.appgw.name
}

# ═══════════════════════════════════════════════════════════════════════════════
# Cross-cutting NSG rules on EXISTING shared NSGs
#
# These rules are added to NSGs already created by phase1/core to allow
# Application Gateway traffic.  Resource names and resource groups are derived
# from the established naming convention (nsg-core-<subnet-suffix>, rg-core).
# ═══════════════════════════════════════════════════════════════════════════════

# ── snet-apim: allow inbound HTTP from App GW ────────────────────────────────
# APIM receives backend traffic from App GW on port 80 (HTTP).
# Existing port 443 rule (VirtualNetwork-scoped) already covers HTTPS;
# port 80 needs an explicit allow since the App GW terminates TLS.

resource "azurerm_network_security_rule" "apim_in_allow_appgw_http" {
  name                        = "allow-inbound-appgw-http"
  priority                    = 140
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = var.appgw_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = "nsg-core-apim"
}

# ── snet-shared-pe: allow inbound HTTPS from App GW ──────────────────────────
# App GW reads its server certificate from Key Vault at runtime.
# The KV PE is in snet-shared-pe; allow the App GW subnet inbound.

resource "azurerm_network_security_rule" "shared_pe_in_allow_appgw" {
  name                        = "allow-inbound-appgw"
  priority                    = 140
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.appgw_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = local.core.resource_group_core
  network_security_group_name = "nsg-core-shared-pe"
}
