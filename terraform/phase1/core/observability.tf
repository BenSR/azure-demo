# ─── Log Analytics Workspace ──────────────────────────────────────────────────
# Centralises all diagnostic logs and metrics. Workspace-based Application
# Insights (in the workload stamp module) also streams here.

resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# ─── Diagnostic Storage Account ───────────────────────────────────────────────
# Required for NSG flow log raw blob storage (Traffic Analytics).
# Public access is not needed — the Network Watcher agent writes directly.

resource "azurerm_storage_account" "diag" {
  name                          = "stdiagcore"
  resource_group_name           = azurerm_resource_group.core.name
  location                      = var.location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  min_tls_version               = "TLS1_2"
  public_network_access_enabled = true # Network Watcher requires public write access for flow logs.
  tags                          = local.tags
}

# ─── Log Analytics self-diagnostic setting ────────────────────────────────────
# Captures LAW audit and usage data back to itself.

resource "azurerm_monitor_diagnostic_setting" "law" {
  name                       = "diag-law-${local.name_suffix}"
  target_resource_id         = azurerm_log_analytics_workspace.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "Audit"
  }
}
