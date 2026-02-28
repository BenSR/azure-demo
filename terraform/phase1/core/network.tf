# ═══════════════════════════════════════════════════════════════════════════════
# Networking — VNet, subnets, NSG rules
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Subnet locals ────────────────────────────────────────────────────────────
# Convert the list of stamps into a map keyed by "<env>-<stamp_name>" for use
# in for_each.  Build a deterministic sorted list so the module receives a
# stable 0-based index for NSG rule priority offsets.

locals {
  stamp_subnets_map = { for s in var.stamp_subnets : "${s.environment}-${s.stamp_name}" => s }
  stamp_keys_sorted = sort(keys(local.stamp_subnets_map))
  stamp_index       = { for i, k in local.stamp_keys_sorted : k => i }
}

# ─── NAT Gateway ─────────────────────────────────────────────────────────────
# Provides deterministic, auditable egress for the GitHub-hosted runner subnet.

resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "this" {
  name                = "nat-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

# ─── Virtual Network ──────────────────────────────────────────────────────────
# The address space is derived from the environment name (see main.tf locals).
# Stamp subnets are defined explicitly via var.stamp_subnets.

module "vnet" {
  source = "../../modules/vnet"

  name                = "vnet-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  address_space       = [local.vnet_address_space]

  subnets = [
    # ── Fixed shared subnets ─────────────────────────────────────────────────
    {
      name             = "snet-apim"
      address_prefixes = [local.subnet_cidrs.apim]
    },
    {
      name                              = "snet-shared-pe"
      address_prefixes                  = [local.subnet_cidrs.shared_pe]
      private_endpoint_network_policies = "Enabled"
    },
    {
      name             = "snet-runner"
      address_prefixes = [local.subnet_cidrs.runner]
      delegation       = "GitHub.Network/networkSettings"
    },
    {
      name             = "snet-jumpbox"
      address_prefixes = [local.subnet_cidrs.jumpbox]
    },
  ]

  # All subnets share the same NAT Gateway for deterministic egress.
  attach_nat_gateway = true
  nat_gateway_id     = azurerm_nat_gateway.this.id

  # Link all 7 Private DNS zones so every subnet resolves PE FQDNs.
  # Keys are static zone name literals (known at plan time); values are the
  # zone resource IDs (apply-time). This avoids the Terraform for_each
  # limitation where set/map keys must be known before apply.
  private_dns_zones = {
    "privatelink.vaultcore.azure.net"    = module.private_dns.key_vault_zone_id
    "privatelink.blob.core.windows.net"  = module.private_dns.blob_storage_zone_id
    "privatelink.file.core.windows.net"  = module.private_dns.file_storage_zone_id
    "privatelink.table.core.windows.net" = module.private_dns.table_storage_zone_id
    "privatelink.queue.core.windows.net" = module.private_dns.queue_storage_zone_id
    "privatelink.azurecr.io"             = module.private_dns.acr_zone_id
    "privatelink.azurewebsites.net"      = module.private_dns.websites_zone_id
  }

  # NSG flow logs.
  flow_logs_enabled            = true
  log_analytics_workspace_id   = azurerm_log_analytics_workspace.this.id
  log_analytics_workspace_guid = azurerm_log_analytics_workspace.this.workspace_id
  flow_log_storage_account_id  = azurerm_storage_account.diag.id

  tags = local.tags

  depends_on = [azurerm_nat_gateway_public_ip_association.this]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Workload Stamp Subnets
#
# Each stamp gets a PE + ASP subnet pair, NSGs, NSG rules, and cross-cutting
# rules on the shared NSGs.  The module is called once per stamp entry in
# var.stamp_subnets.
# ═══════════════════════════════════════════════════════════════════════════════

module "workload_stamp_subnet" {
  for_each = local.stamp_subnets_map
  source   = "../../modules/workload-stamp-subnet"

  environment = each.value.environment
  stamp_name  = each.value.stamp_name
  stamp_index = local.stamp_index[each.key]

  subnet_pe_cidr  = each.value.subnet_pe_cidr
  subnet_asp_cidr = each.value.subnet_asp_cidr

  vnet_name           = module.vnet.vnet_name
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  nsg_name_prefix     = replace(module.vnet.vnet_name, "vnet-", "nsg-")

  shared_subnet_cidrs = {
    apim      = local.subnet_cidrs.apim
    shared_pe = local.subnet_cidrs.shared_pe
    runner    = local.subnet_cidrs.runner
    jumpbox   = local.subnet_cidrs.jumpbox
  }

  shared_nsg_names = {
    apim      = module.vnet.nsg_names["snet-apim"]
    shared_pe = module.vnet.nsg_names["snet-shared-pe"]
    runner    = module.vnet.nsg_names["snet-runner"]
    jumpbox   = module.vnet.nsg_names["snet-jumpbox"]
  }

  flow_logs_enabled            = true
  log_analytics_workspace_id   = azurerm_log_analytics_workspace.this.id
  log_analytics_workspace_guid = azurerm_log_analytics_workspace.this.workspace_id
  flow_log_storage_account_id  = azurerm_storage_account.diag.id

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# NSG Rules — Shared Subnets
# All NSGs are created (empty) by the vnet module.  Rules are managed here so
# they can reference cross-cutting locals (subnet CIDRs) and module outputs.
#
# Per-stamp NSG rules and cross-cutting rules that target stamp subnets are
# managed by the workload-stamp-subnet module above.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── snet-apim  (API Management — internal VNet mode) ─────────────────────────
# APIM in internal VNet mode requires specific management-plane rules.
# See: https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet

resource "azurerm_network_security_rule" "apim_in_allow_vnet_https" {
  name                        = "allow-inbound-vnet-https"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_in_allow_mgmt" {
  # Required by Azure to manage the APIM service over port 3443.
  name                        = "allow-inbound-apim-management"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3443"
  source_address_prefix       = "ApiManagement"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_in_allow_lb_health" {
  # Azure Load Balancer health probes for the APIM gateway.
  name                        = "allow-inbound-lb-health"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_in_allow_jumpbox" {
  name                        = "allow-inbound-jumpbox"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.subnet_cidrs.jumpbox
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_out_allow_shared_pe" {
  name                        = "allow-outbound-shared-pe"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = local.subnet_cidrs.shared_pe
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_out_allow_storage" {
  name                        = "allow-outbound-storage"
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "Storage"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_out_allow_sql" {
  name                        = "allow-outbound-sql"
  priority                    = 130
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "1433"
  source_address_prefix       = "*"
  destination_address_prefix  = "Sql"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_out_allow_eventhub" {
  name                        = "allow-outbound-eventhub"
  priority                    = 140
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "EventHub"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_out_allow_monitor" {
  name                        = "allow-outbound-azure-monitor"
  priority                    = 150
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "AzureMonitor"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_out_allow_aad" {
  name                        = "allow-outbound-aad"
  priority                    = 160
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "AzureActiveDirectory"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_out_allow_keyvault" {
  name                        = "allow-outbound-keyvault"
  priority                    = 170
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "AzureKeyVault"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

resource "azurerm_network_security_rule" "apim_out_allow_dns" {
  name                        = "allow-outbound-dns"
  priority                    = 180
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-apim"]
}

# ─── snet-shared-pe  (ACR Private Endpoint) ───────────────────────────────────
# Inbound from each stamp's ASP subnet is managed by the workload-stamp-subnet
# module.  Static inbound rules for runner, APIM, and jumpbox are below.
# Note: Key Vault has moved into each stamp's PE subnet.

resource "azurerm_network_security_rule" "shared_pe_in_allow_runner" {
  name                        = "allow-inbound-runner"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.subnet_cidrs.runner
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-shared-pe"]
}

resource "azurerm_network_security_rule" "shared_pe_in_allow_apim" {
  name                        = "allow-inbound-apim"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.subnet_cidrs.apim
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-shared-pe"]
}

resource "azurerm_network_security_rule" "shared_pe_in_allow_jumpbox" {
  name                        = "allow-inbound-jumpbox"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.subnet_cidrs.jumpbox
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-shared-pe"]
}

resource "azurerm_network_security_rule" "shared_pe_out_deny_all" {
  name                        = "deny-all-outbound"
  priority                    = 4000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-shared-pe"]
}

# ─── snet-runner  (GitHub-hosted runner — internet egress via NAT GW) ─────────

resource "azurerm_network_security_rule" "runner_in_deny_all" {
  name                        = "deny-all-inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-runner"]
}

resource "azurerm_network_security_rule" "runner_out_allow_shared_pe" {
  name                        = "allow-outbound-shared-pe"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = local.subnet_cidrs.shared_pe
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-runner"]
}

resource "azurerm_network_security_rule" "runner_out_allow_internet_https" {
  name                        = "allow-outbound-internet-https"
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-runner"]
}

resource "azurerm_network_security_rule" "runner_out_allow_internet_http" {
  name                        = "allow-outbound-internet-http"
  priority                    = 130
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-runner"]
}

resource "azurerm_network_security_rule" "runner_out_allow_dns" {
  name                        = "allow-outbound-dns"
  priority                    = 140
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-runner"]
}

# ─── snet-jumpbox  (Windows jump box) ─────────────────────────────────────────

resource "azurerm_network_security_rule" "jumpbox_in_allow_rdp" {
  # In production, replace with Azure Bastion and remove this rule.
  name                        = "allow-inbound-rdp"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-jumpbox"]
}

resource "azurerm_network_security_rule" "jumpbox_out_allow_shared_pe" {
  name                        = "allow-outbound-shared-pe"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = local.subnet_cidrs.shared_pe
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-jumpbox"]
}

resource "azurerm_network_security_rule" "jumpbox_out_allow_apim" {
  name                        = "allow-outbound-apim"
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = local.subnet_cidrs.apim
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-jumpbox"]
}

resource "azurerm_network_security_rule" "jumpbox_out_allow_aad" {
  name                        = "allow-outbound-aad"
  priority                    = 130
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "AzureActiveDirectory"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-jumpbox"]
}

resource "azurerm_network_security_rule" "jumpbox_out_allow_dns" {
  name                        = "allow-outbound-dns"
  priority                    = 140
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-jumpbox"]
}

resource "azurerm_network_security_rule" "jumpbox_out_deny_internet" {
  name                        = "deny-outbound-internet"
  priority                    = 4000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  resource_group_name         = azurerm_resource_group.core.name
  network_security_group_name = module.vnet.nsg_names["snet-jumpbox"]
}
