# ─── Workload Stamp Module — Unit Tests ───────────────────────────────────────
# Uses mock providers so no Azure credentials are required.
# All runs use command = plan to avoid mock-provider ID-format issues
# with resources that validate ARM resource ID syntax at apply time
# (role_assignment scope, private_endpoint connection_resource_id,
# diagnostic_setting target_resource_id, function_app service_plan_id).
# Run: terraform -chdir=terraform/modules/workload-stamp test

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "11111111-1111-1111-1111-111111111111"
      object_id       = "22222222-2222-2222-2222-222222222222"
    }
  }
}

mock_provider "azuread" {
  mock_data "azuread_user" {
    defaults = {
      object_id = "33333333-3333-3333-3333-333333333333"
    }
  }
}

variables {
  stamp_number               = 1
  environment                = "dev"
  resource_group_name        = "rg-wkld-dev"
  location                   = "uksouth"
  subnet_id                  = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.Network/virtualNetworks/vnet-wkld-shared-dev/subnets/snet-stamp-dev-1-asp"
  private_endpoint_subnet_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.Network/virtualNetworks/vnet-wkld-shared-dev/subnets/snet-stamp-dev-1-pe"
  acr_id                     = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.ContainerRegistry/registries/acrcore"
  log_analytics_workspace_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.OperationalInsights/workspaces/law-core"
  apim_principal_id          = "44444444-4444-4444-4444-444444444444"
  entra_app_client_id        = "55555555-5555-5555-5555-555555555555"
  admin_user_principal_name  = "admin@example.com"
  private_dns_zone_ids = {
    blob_storage_zone_id  = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    file_storage_zone_id  = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net"
    table_storage_zone_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net"
    queue_storage_zone_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net"
    websites_zone_id      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net"
    key_vault_zone_id     = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-core-dev/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }
  function_apps = {
    "func-wkld-1-dev" = {
      registry_url = "acrcore.azurecr.io"
      image_name   = "function-app"
      image_tag    = "dev"
    }
  }
}

# ─── Resource naming convention ───────────────────────────────────────────────

run "resource_naming_convention" {
  command = plan

  assert {
    condition     = azurerm_storage_account.this.name == "stwkld1dev"
    error_message = "Storage account name must be stwkld1dev"
  }

  assert {
    condition     = azurerm_service_plan.this.name == "asp-wkld-1-dev"
    error_message = "App Service Plan name must be asp-wkld-1-dev"
  }

  assert {
    condition     = azurerm_key_vault.this.name == "kv-wkld-1-dev"
    error_message = "Key Vault name must be kv-wkld-1-dev"
  }

  assert {
    condition     = azurerm_application_insights.this.name == "appi-wkld-1-dev"
    error_message = "Application Insights name must be appi-wkld-1-dev"
  }
}

# ─── Storage Account hardening ────────────────────────────────────────────────

run "storage_account_hardening" {
  command = plan

  assert {
    condition     = azurerm_storage_account.this.public_network_access_enabled == false
    error_message = "Storage account must have public_network_access_enabled = false"
  }

  assert {
    condition     = azurerm_storage_account.this.min_tls_version == "TLS1_2"
    error_message = "Storage account must enforce TLS 1.2"
  }

  assert {
    condition     = azurerm_storage_account.this.network_rules[0].default_action == "Deny"
    error_message = "Storage account default network action must be Deny"
  }
}

# ─── Function App configuration ──────────────────────────────────────────────

run "function_app_config" {
  command = plan

  # Network hardening
  assert {
    condition     = azurerm_linux_function_app.this["func-wkld-1-dev"].public_network_access_enabled == false
    error_message = "Function App must have public_network_access_enabled = false"
  }

  assert {
    condition     = azurerm_linux_function_app.this["func-wkld-1-dev"].https_only == true
    error_message = "Function App must enforce HTTPS-only"
  }

  assert {
    condition     = azurerm_linux_function_app.this["func-wkld-1-dev"].virtual_network_subnet_id == var.subnet_id
    error_message = "Function App must be VNet-integrated via the delegated ASP subnet"
  }

  # Managed Identity
  assert {
    condition     = azurerm_linux_function_app.this["func-wkld-1-dev"].identity[0].type == "SystemAssigned"
    error_message = "Function App must have a system-assigned Managed Identity"
  }

  # Storage via MI
  assert {
    condition     = azurerm_linux_function_app.this["func-wkld-1-dev"].storage_uses_managed_identity == true
    error_message = "Function App must access storage via Managed Identity"
  }

  # Linux ASP
  assert {
    condition     = azurerm_service_plan.this.os_type == "Linux"
    error_message = "App Service Plan must use Linux OS type"
  }
}

# ─── Function App EasyAuth ────────────────────────────────────────────────────

run "function_app_easyauth" {
  command = plan

  assert {
    condition     = azurerm_linux_function_app.this["func-wkld-1-dev"].auth_settings_v2[0].auth_enabled == true
    error_message = "EasyAuth must be enabled"
  }

  assert {
    condition     = azurerm_linux_function_app.this["func-wkld-1-dev"].auth_settings_v2[0].require_authentication == true
    error_message = "EasyAuth must require authentication"
  }

  assert {
    condition     = azurerm_linux_function_app.this["func-wkld-1-dev"].auth_settings_v2[0].unauthenticated_action == "Return401"
    error_message = "Unauthenticated requests must receive HTTP 401"
  }

  assert {
    condition     = contains(azurerm_linux_function_app.this["func-wkld-1-dev"].auth_settings_v2[0].excluded_paths, "/api/health")
    error_message = "Health endpoint must be excluded from EasyAuth"
  }
}

# ─── Key Vault hardening ─────────────────────────────────────────────────────

run "key_vault_hardening" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.public_network_access_enabled == false
    error_message = "Key Vault must have public_network_access_enabled = false"
  }

  assert {
    condition     = azurerm_key_vault.this.enable_rbac_authorization == true
    error_message = "Key Vault must use RBAC authorization"
  }

  assert {
    condition     = azurerm_key_vault.this.soft_delete_retention_days == 7
    error_message = "Key Vault soft_delete_retention_days must be 7"
  }

  assert {
    condition     = azurerm_key_vault.this.sku_name == "standard"
    error_message = "Key Vault must use standard SKU"
  }
}

# ─── Role assignments ────────────────────────────────────────────────────────

run "role_assignments" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.acr_pull) == 1
    error_message = "One AcrPull role assignment per Function App"
  }

  assert {
    condition     = azurerm_role_assignment.acr_pull["func-wkld-1-dev"].role_definition_name == "AcrPull"
    error_message = "ACR role must be AcrPull"
  }

  assert {
    condition     = length(azurerm_role_assignment.storage_blob_owner) == 1
    error_message = "One Storage Blob Data Owner role per Function App"
  }
}

# ─── Application Insights ────────────────────────────────────────────────────

run "application_insights" {
  command = plan

  assert {
    condition     = azurerm_application_insights.this.application_type == "web"
    error_message = "Application Insights must have application_type = web"
  }

  assert {
    condition     = azurerm_application_insights.this.workspace_id == var.log_analytics_workspace_id
    error_message = "Application Insights must be backed by the shared Log Analytics Workspace"
  }
}
