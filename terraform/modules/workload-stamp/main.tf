locals {
  stamp_prefix       = "${var.workload_name}-${var.stamp_number}-${var.environment}"
  stamp_prefix_clean = "${var.workload_name}${var.stamp_number}${var.environment}"
}

# ─── Application Insights ─────────────────────────────────────────────────────
# Workspace-based, backed by the shared Log Analytics Workspace.

resource "azurerm_application_insights" "this" {
  name                = "appi-${local.stamp_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = var.log_analytics_workspace_id
  application_type    = "web"
  tags                = var.tags
}

# ─── Storage Account ──────────────────────────────────────────────────────────
# Backing storage for the Function App.  Public access disabled; all traffic
# routes via Private Endpoints in the stamp PE subnet.

resource "azurerm_storage_account" "this" {
  name                          = "st${local.stamp_prefix_clean}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  min_tls_version               = "TLS1_2"
  public_network_access_enabled = false

  # Deny all network access by default; Private Endpoints provide connectivity.
  # AzureServices bypass is required for the Function App platform itself.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = var.tags
}

# ─── App Service Plan ─────────────────────────────────────────────────────────
# Linux plan shared by all Function Apps in this stamp.

resource "azurerm_service_plan" "this" {
  name                = "asp-${local.stamp_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.asp_sku
  tags                = var.tags
}

# ─── Function Apps ────────────────────────────────────────────────────────────
# Container-based (Docker image pulled from ACR), VNet-integrated, with a
# system-assigned Managed Identity for secretless access to ACR, Key Vault,
# and Storage.

resource "azurerm_linux_function_app" "this" {
  for_each = var.function_apps

  name                = each.key
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id

  # Managed Identity is used for storage access — no storage account key stored.
  storage_account_name          = azurerm_storage_account.this.name
  storage_uses_managed_identity = true

  public_network_access_enabled = false
  https_only                    = true

  # Enable publishing credentials so the Kudu container deployment webhook URL
  # can be retrieved and stored in Key Vault for CI/CD use.
  webdeploy_publish_basic_authentication_enabled = true

  # Outbound traffic from the Function App leaves via this VNet-integrated subnet.
  virtual_network_subnet_id = var.subnet_id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    minimum_tls_version = "1.2"
    always_on           = true

    # Authenticate to ACR using the Function App's system-assigned Managed Identity.
    container_registry_use_managed_identity = true

    application_stack {
      docker {
        registry_url = each.value.registry_url
        image_name   = each.value.image_name
        image_tag    = each.value.image_tag
      }
    }

    application_insights_connection_string = azurerm_application_insights.this.connection_string
    application_insights_key               = azurerm_application_insights.this.instrumentation_key
  }

  app_settings = merge(
    {
      APPLICATIONINSIGHTS_CONNECTION_STRING      = azurerm_application_insights.this.connection_string
      ApplicationInsightsAgent_EXTENSION_VERSION = "~3"
      FUNCTIONS_EXTENSION_VERSION                = "~4"
      # Disable the built-in App Service storage mount; blobs are accessed via PE.
      WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    },
    each.value.app_settings
  )

  # ── EasyAuth v2 ────────────────────────────────────────────────────────────
  # Validates Entra ID JWTs issued by APIM's Managed Identity before requests
  # reach function code (Section 12.4, app-planning.md).
  #
  # /api/health is excluded — App Insights availability tests and APIM health
  # probes do not carry tokens.  The endpoint returns no sensitive data and is
  # only reachable from inside the VNet (NSGs restrict the PE subnet).
  auth_settings_v2 {
    auth_enabled           = true
    require_authentication = true
    unauthenticated_action = "Return401"
    excluded_paths         = ["/api/health"]

    active_directory_v2 {
      client_id            = var.entra_app_client_id
      tenant_auth_endpoint = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"

      # Token audience must match the identifier_uri of the Entra app registration.
      allowed_audiences = [
        "api://func-${var.workload_name}-${var.stamp_number}-api-${var.environment}"
      ]
    }

    login {
      token_store_enabled = false
    }
  }

  tags = var.tags
}
