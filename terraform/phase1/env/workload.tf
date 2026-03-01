# ─── Workload Stamps ───────────────────────────────────────────────────────────
# One workload-stamp module instance is created per entry in var.stamps.
# Each stamp deploys its own:
#   - App Service Plan (P1v3)
#   - Function App(s)
#   - Storage Account
#   - Application Insights
#   - Key Vault + KV Private Endpoint
#   - Private Endpoints (storage × 4 + Function App)
#   - Role assignments (AcrPull, KV roles for func/APIM/CI-CD, Storage roles)
#   - Diagnostic settings
#
# Subnet IDs, ACR details, LAW ID, and DNS zone IDs are read from the
# phase1/core remote state via local.core.

locals {
  # Convert the stamps list into a map keyed by stamp_name for use in for_each.
  stamps_map = { for s in var.stamps : s.stamp_name => s }
}

module "workload_stamp" {
  for_each = local.stamps_map
  source   = "../../modules/workload-stamp"

  workload_name       = local.workload
  stamp_number        = tonumber(each.key)
  environment         = local.environment
  resource_group_name = azurerm_resource_group.stamp[each.key].name
  location            = each.value.location

  asp_sku = "B1"

  # Single Function App per stamp.
  # Name: func-<workload>-<stamp_name>-api-<env>
  function_apps = {
    "func-${local.workload}-${each.key}-api-${local.environment}" = {
      registry_url = local.core.acr_login_server
      image_name   = each.value.image_name
      image_tag    = each.value.image_tag
    }
  }

  # Subnet names follow the convention established in phase1/core:
  #   snet-stamp-<env>-<stamp_name>-asp  — delegated to Microsoft.Web/serverFarms
  #   snet-stamp-<env>-<stamp_name>-pe   — hosts all Private Endpoints
  subnet_id                  = local.core.subnet_ids["snet-stamp-${local.environment}-${each.key}-asp"]
  private_endpoint_subnet_id = local.core.subnet_ids["snet-stamp-${local.environment}-${each.key}-pe"]

  acr_id                     = local.core.acr_id
  log_analytics_workspace_id = local.core.log_analytics_workspace_id

  # Entra app registration client_id — used by auth_settings_v2 (EasyAuth) on
  # the Function App to validate tokens issued by APIM's Managed Identity.
  entra_app_client_id = azuread_application.func_api[each.key].client_id

  # APIM MI needs KV access to retrieve mTLS certs in Phase 3.
  apim_principal_id = azurerm_api_management.this.identity[0].principal_id

  private_dns_zone_ids = {
    blob_storage_zone_id  = local.core.private_dns_zone_ids.blob_storage_zone_id
    file_storage_zone_id  = local.core.private_dns_zone_ids.file_storage_zone_id
    table_storage_zone_id = local.core.private_dns_zone_ids.table_storage_zone_id
    queue_storage_zone_id = local.core.private_dns_zone_ids.queue_storage_zone_id
    websites_zone_id      = local.core.private_dns_zone_ids.websites_zone_id
    key_vault_zone_id     = local.core.private_dns_zone_ids.key_vault_zone_id
  }

  tags = local.tags
}
