# ─── VNet Module — Unit Tests ─────────────────────────────────────────────────
# Uses mock providers so no Azure credentials are required.
# Run: terraform -chdir=terraform/modules/vnet test

mock_provider "azurerm" {}

variables {
  name                = "vnet-wkld-shared-dev"
  resource_group_name = "rg-core-dev"
  location            = "uksouth"
  address_space       = ["10.100.0.0/16"]
  subnets = [
    {
      name             = "snet-runner"
      address_prefixes = ["10.100.128.0/24"]
    },
    {
      name             = "snet-jumpbox"
      address_prefixes = ["10.100.129.0/27"]
    },
    {
      name             = "snet-apim"
      address_prefixes = ["10.100.129.32/27"]
    },
  ]
}

# ─── VNet name and address space ──────────────────────────────────────────────

run "vnet_name_and_address_space" {
  command = apply

  assert {
    condition     = azurerm_virtual_network.this.name == "vnet-wkld-shared-dev"
    error_message = "VNet name must match var.name"
  }

  assert {
    condition     = azurerm_virtual_network.this.address_space == tolist(["10.100.0.0/16"])
    error_message = "VNet address space must match var.address_space"
  }

  assert {
    condition     = azurerm_virtual_network.this.resource_group_name == "rg-core-dev"
    error_message = "VNet resource group must match var.resource_group_name"
  }

  assert {
    condition     = output.vnet_name == "vnet-wkld-shared-dev"
    error_message = "vnet_name output must match var.name"
  }
}

# ─── One NSG per subnet ───────────────────────────────────────────────────────

run "one_nsg_per_subnet" {
  command = apply

  assert {
    condition     = length(azurerm_subnet.this) == 3
    error_message = "Expected one subnet resource per entry in var.subnets"
  }

  assert {
    condition     = length(azurerm_network_security_group.this) == 3
    error_message = "Expected one NSG per subnet"
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.this) == 3
    error_message = "Expected one NSG-subnet association per subnet"
  }

  assert {
    condition     = length(output.subnet_ids) == 3
    error_message = "subnet_ids output must contain one entry per subnet"
  }

  assert {
    condition     = length(output.nsg_ids) == 3
    error_message = "nsg_ids output must contain one entry per subnet"
  }
}

# ─── NSG naming convention ────────────────────────────────────────────────────
# Convention: vnet-wkld-shared-dev + snet-runner → nsg-wkld-shared-dev-runner

run "nsg_naming_convention" {
  command = apply

  assert {
    condition     = azurerm_network_security_group.this["snet-runner"].name == "nsg-wkld-shared-dev-runner"
    error_message = "Runner NSG should be named nsg-wkld-shared-dev-runner"
  }

  assert {
    condition     = azurerm_network_security_group.this["snet-jumpbox"].name == "nsg-wkld-shared-dev-jumpbox"
    error_message = "Jumpbox NSG should be named nsg-wkld-shared-dev-jumpbox"
  }

  assert {
    condition     = azurerm_network_security_group.this["snet-apim"].name == "nsg-wkld-shared-dev-apim"
    error_message = "APIM NSG should be named nsg-wkld-shared-dev-apim"
  }

  assert {
    condition     = output.nsg_names["snet-runner"] == "nsg-wkld-shared-dev-runner"
    error_message = "nsg_names output must expose the derived NSG name for snet-runner"
  }
}

# ─── subnet_ids keys match subnet names ───────────────────────────────────────

run "output_keys_match_subnet_names" {
  command = apply

  assert {
    condition     = contains(keys(output.subnet_ids), "snet-runner")
    error_message = "subnet_ids output must include snet-runner"
  }

  assert {
    condition     = contains(keys(output.subnet_ids), "snet-jumpbox")
    error_message = "subnet_ids output must include snet-jumpbox"
  }

  assert {
    condition     = contains(keys(output.subnet_ids), "snet-apim")
    error_message = "subnet_ids output must include snet-apim"
  }
}

# ─── No NAT gateway associations when attach_nat_gateway = false ──────────────

run "no_nat_gateway_by_default" {
  command = apply

  assert {
    condition     = length(azurerm_subnet_nat_gateway_association.this) == 0
    error_message = "No NAT gateway associations should be created when attach_nat_gateway is false"
  }
}

# ─── No flow logs when flow_logs_enabled = false ─────────────────────────────

run "no_flow_logs_by_default" {
  command = apply

  assert {
    condition     = length(azurerm_network_watcher_flow_log.this) == 0
    error_message = "No flow logs should be created when flow_logs_enabled is false"
  }
}
