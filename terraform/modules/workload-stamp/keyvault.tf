# ─── Key Vault ────────────────────────────────────────────────────────────────
# Each stamp owns its own Key Vault so the stamp is a self-contained regional
# unit.  If a region fails, the stamp's KV fails with it rather than taking
# down a shared KV that other stamps depend on.
#
# RBAC authorisation model is used so that role assignments work uniformly for
# all consumers (Function Apps, APIM, CI/CD SP).
# Naming: kv-<workload>-<stamp_number>-<env> → e.g. kv-wkld-1-dev

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                       = "kv-${local.stamp_prefix}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # Assessment: allow clean teardown.

  # All access via Private Endpoint; no public data-plane access.
  public_network_access_enabled = false

  tags = var.tags
}

# ─── Key Vault — Private Endpoint ─────────────────────────────────────────────
# Placed in the stamp's PE subnet (snet-stamp-<N>-pe) alongside storage PEs.

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-kv-${local.stamp_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-kv-${local.stamp_prefix}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dzg-kv"
    private_dns_zone_ids = [var.private_dns_zone_ids.key_vault_zone_id]
  }

  tags = var.tags
}

# ─── Key Vault — diagnostic settings ──────────────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-kv-${local.stamp_prefix}"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }
}
