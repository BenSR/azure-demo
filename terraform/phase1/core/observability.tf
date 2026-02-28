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
