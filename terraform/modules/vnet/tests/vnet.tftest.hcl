# ─── VNet Module — Unit Tests ─────────────────────────────────────────────────
# Uses mock providers so no Azure credentials are required.
# All runs use command = plan to avoid mock-provider ID-format issues
# with resources like azurerm_subnet_network_security_group_association
# that validate ARM resource ID syntax at apply time.
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

# ─── Core resources: VNet, subnets, NSGs ──────────────────────────────────────

run "core_resources" {
  command = plan

  # VNet
  assert {
    condition     = azurerm_virtual_network.this.name == "vnet-wkld-shared-dev"
    error_message = "VNet name must match var.name"
  }

  assert {
    condition     = azurerm_virtual_network.this.address_space == tolist(["10.100.0.0/16"])
    error_message = "VNet address space must match var.address_space"
  }

  # One subnet + NSG per entry
  assert {
    condition     = length(azurerm_subnet.this) == 3
    error_message = "Expected one subnet per var.subnets entry"
  }

  assert {
    condition     = length(azurerm_network_security_group.this) == 3
    error_message = "Expected one NSG per subnet"
  }

  assert {
    condition     = length(azurerm_subnet_network_security_group_association.this) == 3
    error_message = "Expected one NSG-subnet association per subnet"
  }
}

# ─── NSG naming convention ────────────────────────────────────────────────────
# vnet-wkld-shared-dev + snet-runner → nsg-wkld-shared-dev-runner

run "nsg_naming_convention" {
  command = plan

  assert {
    condition     = azurerm_network_security_group.this["snet-runner"].name == "nsg-wkld-shared-dev-runner"
    error_message = "Runner NSG should be nsg-wkld-shared-dev-runner"
  }

  assert {
    condition     = azurerm_network_security_group.this["snet-jumpbox"].name == "nsg-wkld-shared-dev-jumpbox"
    error_message = "Jumpbox NSG should be nsg-wkld-shared-dev-jumpbox"
  }

  assert {
    condition     = azurerm_network_security_group.this["snet-apim"].name == "nsg-wkld-shared-dev-apim"
    error_message = "APIM NSG should be nsg-wkld-shared-dev-apim"
  }
}

# ─── Optional resources off by default ────────────────────────────────────────

run "optional_resources_off_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_subnet_nat_gateway_association.this) == 0
    error_message = "No NAT gateway associations when attach_nat_gateway is false"
  }

  assert {
    condition     = length(azurerm_network_watcher_flow_log.this) == 0
    error_message = "No flow logs should be created when flow_logs_enabled is false"
  }
}
