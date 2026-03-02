# ─── Log Analytics Workspace ──────────────────────────────────────────────────
# Centralises all diagnostic logs. Workspace-based Application Insights
# (in the workload stamp module) also streams here.

resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.core.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# ─── Log Analytics Workspace — Self-Diagnostic Setting ─────────────────────────
# Exports the LAW's own audit logs back into itself for administrative
# change tracking (workspace queries, access, configuration changes).

resource "azurerm_monitor_diagnostic_setting" "law" {
  name                       = "diag-law-${local.name_suffix}"
  target_resource_id         = azurerm_log_analytics_workspace.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "Audit"
  }

  metric {
    category = "AllMetrics"
  }
}
