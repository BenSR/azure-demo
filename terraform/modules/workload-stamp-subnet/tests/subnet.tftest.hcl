# ─── Workload Stamp Subnet Module — Unit Tests ────────────────────────────────
# Uses mock providers so no Azure credentials are required.
# All runs use command = plan to avoid mock-provider ID-format issues
# with resources like azurerm_subnet_network_security_group_association
# that validate ARM resource ID syntax at apply time.
# Run: terraform -chdir=terraform/modules/workload-stamp-subnet test

mock_provider "azurerm" {}

variables {
  environment         = "dev"
  stamp_name          = "1"
  stamp_index         = 0
  subnet_pe_cidr      = "10.100.0.0/24"
  subnet_asp_cidr     = "10.100.1.0/24"
  vnet_name           = "vnet-wkld-shared-dev"
  resource_group_name = "rg-core-dev"
  location            = "uksouth"
  nsg_name_prefix     = "nsg-core"
  shared_subnet_cidrs = {
    apim      = "10.100.129.32/27"
    shared_pe = "10.100.130.0/24"
    runner    = "10.100.128.0/24"
    jumpbox   = "10.100.129.0/27"
  }
  shared_nsg_names = {
    apim      = "nsg-core-apim"
    shared_pe = "nsg-core-shared-pe"
    runner    = "nsg-core-runner"
    jumpbox   = "nsg-core-jumpbox"
  }
}

# ─── Subnet naming, CIDRs, and configuration ─────────────────────────────────

run "subnet_configuration" {
  command = plan

  # Naming convention: snet-stamp-<env>-<stamp_name>-<pe|asp>
  assert {
    condition     = azurerm_subnet.pe.name == "snet-stamp-dev-1-pe"
    error_message = "PE subnet name must be snet-stamp-dev-1-pe"
  }

  assert {
    condition     = azurerm_subnet.asp.name == "snet-stamp-dev-1-asp"
    error_message = "ASP subnet name must be snet-stamp-dev-1-asp"
  }

  # CIDRs
  assert {
    condition     = azurerm_subnet.pe.address_prefixes == tolist(["10.100.0.0/24"])
    error_message = "PE subnet address prefix must match var.subnet_pe_cidr"
  }

  assert {
    condition     = azurerm_subnet.asp.address_prefixes == tolist(["10.100.1.0/24"])
    error_message = "ASP subnet address prefix must match var.subnet_asp_cidr"
  }

  # PE subnet network policies
  assert {
    condition     = azurerm_subnet.pe.private_endpoint_network_policies == "Enabled"
    error_message = "PE subnet must have private_endpoint_network_policies = Enabled"
  }

  # ASP delegation
  assert {
    condition     = azurerm_subnet.asp.delegation[0].service_delegation[0].name == "Microsoft.Web/serverFarms"
    error_message = "ASP subnet must be delegated to Microsoft.Web/serverFarms"
  }
}

# ─── PE NSG rules ─────────────────────────────────────────────────────────────

run "pe_nsg_rules" {
  command = plan

  # Deny-all outbound
  assert {
    condition     = azurerm_network_security_rule.pe_out_deny_all.priority == 4000
    error_message = "PE deny-all-outbound rule must be at priority 4000"
  }

  assert {
    condition     = azurerm_network_security_rule.pe_out_deny_all.access == "Deny" && azurerm_network_security_rule.pe_out_deny_all.direction == "Outbound"
    error_message = "PE deny-all-outbound rule must deny outbound traffic"
  }

  # Inbound allow from APIM
  assert {
    condition     = azurerm_network_security_rule.pe_in_allow_apim.priority == 100
    error_message = "PE APIM inbound allow rule must be at priority 100"
  }

  assert {
    condition     = azurerm_network_security_rule.pe_in_allow_apim.destination_port_range == "443"
    error_message = "PE APIM inbound allow rule must target port 443"
  }

  assert {
    condition     = azurerm_network_security_rule.pe_in_allow_apim.source_address_prefix == var.shared_subnet_cidrs.apim
    error_message = "PE APIM allow rule source must be the APIM subnet CIDR"
  }
}

# ─── ASP NSG rules ────────────────────────────────────────────────────────────

run "asp_nsg_rules" {
  command = plan

  # Deny Internet outbound
  assert {
    condition     = azurerm_network_security_rule.asp_out_deny_internet.priority == 4000
    error_message = "ASP deny-internet-outbound rule must be at priority 4000"
  }

  assert {
    condition     = azurerm_network_security_rule.asp_out_deny_internet.destination_address_prefix == "Internet" && azurerm_network_security_rule.asp_out_deny_internet.access == "Deny"
    error_message = "ASP deny-internet-outbound rule must deny Internet traffic"
  }

  # Azure Monitor outbound
  assert {
    condition     = azurerm_network_security_rule.asp_out_allow_monitor.destination_address_prefix == "AzureMonitor" && azurerm_network_security_rule.asp_out_allow_monitor.access == "Allow"
    error_message = "ASP NSG must allow outbound to AzureMonitor service tag"
  }
}

# ─── Cross-cutting rules: priorities and targets ─────────────────────────────

run "cross_cutting_rules" {
  command = plan

  # Priorities offset by stamp_index (0)
  assert {
    condition     = azurerm_network_security_rule.shared_apim_out_allow_stamp_pe.priority == 100
    error_message = "APIM cross-cutting rule priority must be 100 + stamp_index"
  }

  assert {
    condition     = azurerm_network_security_rule.shared_pe_in_allow_stamp_asp.priority == 100
    error_message = "Shared PE cross-cutting rule priority must be 100 + stamp_index"
  }

  assert {
    condition     = azurerm_network_security_rule.shared_runner_out_allow_stamp_pe.priority == 100
    error_message = "Runner cross-cutting rule priority must be 100 + stamp_index"
  }

  assert {
    condition     = azurerm_network_security_rule.shared_jumpbox_out_allow_stamp_pe.priority == 100
    error_message = "Jumpbox cross-cutting rule priority must be 100 + stamp_index"
  }

  # Targets correct stamp PE CIDR
  assert {
    condition     = azurerm_network_security_rule.shared_apim_out_allow_stamp_pe.destination_address_prefix == var.subnet_pe_cidr
    error_message = "APIM outbound cross-cutting rule must target the stamp PE subnet CIDR"
  }

  assert {
    condition     = azurerm_network_security_rule.shared_runner_out_allow_stamp_pe.destination_address_prefix == var.subnet_pe_cidr
    error_message = "Runner outbound cross-cutting rule must target the stamp PE subnet CIDR"
  }
}

# ─── Optional resources off by default ────────────────────────────────────────

run "no_flow_logs_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_network_watcher_flow_log.pe) == 0
    error_message = "No PE flow logs should be created when flow_logs_enabled is false"
  }

  assert {
    condition     = length(azurerm_network_watcher_flow_log.asp) == 0
    error_message = "No ASP flow logs should be created when flow_logs_enabled is false"
  }
}

# ─── Second stamp uses a different priority offset ────────────────────────────

run "second_stamp_offset" {
  command = plan

  variables {
    stamp_index = 1
    stamp_name  = "2"
  }

  assert {
    condition     = azurerm_network_security_rule.shared_apim_out_allow_stamp_pe.priority == 101
    error_message = "Second stamp APIM rule must be at priority 101 (100 + 1)"
  }

  assert {
    condition     = azurerm_subnet.pe.name == "snet-stamp-dev-2-pe"
    error_message = "Second stamp PE subnet must be named snet-stamp-dev-2-pe"
  }
}
