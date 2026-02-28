# ─── Function App — Diagnostic Settings ──────────────────────────────────────
# Captures function execution logs (stdout, exceptions, host output) into the
# shared Log Analytics Workspace.  Application Insights already captures
# request telemetry and dependencies; this catches low-level runtime output.

resource "azurerm_monitor_diagnostic_setting" "function_app" {
  for_each = var.function_apps

  name                       = "diag-${each.key}"
  target_resource_id         = azurerm_linux_function_app.this[each.key].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "FunctionAppLogs"
  }
}
