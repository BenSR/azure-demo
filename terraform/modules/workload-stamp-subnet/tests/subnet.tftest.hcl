# ─── Workload Stamp Subnet Module — Unit Tests ────────────────────────────────
# Uses mock providers so no Azure credentials are required.
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

# ─── Subnet naming convention ─────────────────────────────────────────────────
# Convention: snet-stamp-<env>-<stamp_name>-<pe|asp>

run "subnet_names_follow_convention" {
  command = apply

  assert {
    condition     = azurerm_subnet.pe.name == "snet-stamp-dev-1-pe"
    error_message = "PE subnet name must be snet-stamp-dev-1-pe"
  }

  assert {
    condition     = azurerm_subnet.asp.name == "snet-stamp-dev-1-asp"
    error_message = "ASP subnet name must be snet-stamp-dev-1-asp"
  }

  assert {
    condition     = output.pe_nsg_name == "nsg-core-stamp-dev-1-pe"
    error_message = "pe_nsg_name output must be nsg-core-stamp-dev-1-pe"
  }

  assert {
    condition     = output.asp_nsg_name == "nsg-core-stamp-dev-1-asp"
    error_message = "asp_nsg_name output must be nsg-core-stamp-dev-1-asp"
  }
}

# ─── PE subnet network policies ───────────────────────────────────────────────
# private_endpoint_network_policies must be Enabled so Private Endpoints
# deployed into this subnet can create their NIC without conflicts.

run "pe_subnet_network_policies_enabled" {
  command = apply

  assert {
    condition     = azurerm_subnet.pe.private_endpoint_network_policies == "Enabled"
    error_message = "PE subnet must have private_endpoint_network_policies = Enabled"
  }
}

# ─── ASP subnet delegation ────────────────────────────────────────────────────

run "asp_subnet_has_web_delegation" {
  command = apply

  assert {
    condition     = azurerm_subnet.asp.delegation[0].service_delegation[0].name == "Microsoft.Web/serverFarms"
    error_message = "ASP subnet must be delegated to Microsoft.Web/serverFarms"
  }
}

# ─── CIDR assignments ─────────────────────────────────────────────────────────

run "subnet_cidrs_match_inputs" {
  command = apply

  assert {
    condition     = azurerm_subnet.pe.address_prefixes == tolist(["10.100.0.0/24"])
    error_message = "PE subnet address prefix must match var.subnet_pe_cidr"
  }

  assert {
    condition     = azurerm_subnet.asp.address_prefixes == tolist(["10.100.1.0/24"])
    error_message = "ASP subnet address prefix must match var.subnet_asp_cidr"
  }
}

# ─── PE NSG: deny-all outbound ────────────────────────────────────────────────
# PEs are passive ingress targets; all outbound traffic must be denied.

run "pe_nsg_deny_all_outbound" {
  command = apply

  assert {
    condition     = azurerm_network_security_rule.pe_out_deny_all.priority == 4000
    error_message = "PE deny-all-outbound rule must be at priority 4000"
  }

  assert {
    condition     = azurerm_network_security_rule.pe_out_deny_all.access == "Deny"
    error_message = "PE deny-all-outbound rule must have access = Deny"
  }

  assert {
    condition     = azurerm_network_security_rule.pe_out_deny_all.direction == "Outbound"
    error_message = "PE deny-all-outbound rule must have direction = Outbound"
  }
}

# ─── PE NSG: inbound allow rules ─────────────────────────────────────────────

run "pe_nsg_inbound_allow_rules" {
  command = apply

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

# ─── ASP NSG: deny Internet outbound ─────────────────────────────────────────
# Function Apps must not be able to reach the public internet directly.

run "asp_nsg_deny_internet_outbound" {
  command = apply

  assert {
    condition     = azurerm_network_security_rule.asp_out_deny_internet.priority == 4000
    error_message = "ASP deny-internet-outbound rule must be at priority 4000"
  }

  assert {
    condition     = azurerm_network_security_rule.asp_out_deny_internet.destination_address_prefix == "Internet"
    error_message = "ASP deny-internet-outbound rule must target the Internet service tag"
  }

  assert {
    condition     = azurerm_network_security_rule.asp_out_deny_internet.access == "Deny"
    error_message = "ASP deny-internet-outbound rule must have access = Deny"
  }
}

# ─── ASP NSG: Azure Monitor outbound ─────────────────────────────────────────

run "asp_nsg_allows_monitor_outbound" {
  command = apply

  assert {
    condition     = azurerm_network_security_rule.asp_out_allow_monitor.destination_address_prefix == "AzureMonitor"
    error_message = "ASP NSG must allow outbound to AzureMonitor service tag"
  }

  assert {
    condition     = azurerm_network_security_rule.asp_out_allow_monitor.access == "Allow"
    error_message = "ASP NSG AzureMonitor rule must have access = Allow"
  }
}

# ─── Cross-cutting rule priorities offset by stamp_index ─────────────────────
# Ensures that adding multiple stamps to shared NSGs does not cause
# priority collisions.

run "cross_cutting_priorities_use_stamp_index" {
  command = apply

  assert {
    condition     = azurerm_network_security_rule.shared_apim_out_allow_stamp_pe.priority == 100 + var.stamp_index
    error_message = "APIM cross-cutting rule priority must be 100 + stamp_index"
  }

  assert {
    condition     = azurerm_network_security_rule.shared_pe_in_allow_stamp_asp.priority == 100 + var.stamp_index
    error_message = "Shared PE cross-cutting rule priority must be 100 + stamp_index"
  }

  assert {
    condition     = azurerm_network_security_rule.shared_runner_out_allow_stamp_pe.priority == 100 + var.stamp_index
    error_message = "Runner cross-cutting rule priority must be 100 + stamp_index"
  }

  assert {
    condition     = azurerm_network_security_rule.shared_jumpbox_out_allow_stamp_pe.priority == 100 + var.stamp_index
    error_message = "Jumpbox cross-cutting rule priority must be 100 + stamp_index"
  }
}

# ─── Cross-cutting rules target correct stamp PE CIDR ────────────────────────

run "cross_cutting_rules_target_stamp_pe_cidr" {
  command = apply

  assert {
    condition     = azurerm_network_security_rule.shared_apim_out_allow_stamp_pe.destination_address_prefix == var.subnet_pe_cidr
    error_message = "APIM outbound cross-cutting rule must target the stamp PE subnet CIDR"
  }

  assert {
    condition     = azurerm_network_security_rule.shared_runner_out_allow_stamp_pe.destination_address_prefix == var.subnet_pe_cidr
    error_message = "Runner outbound cross-cutting rule must target the stamp PE subnet CIDR"
  }
}

# ─── No flow logs created by default ─────────────────────────────────────────

run "no_flow_logs_by_default" {
  command = apply

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

run "second_stamp_priorities_are_offset" {
  command = apply

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
