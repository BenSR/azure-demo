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

# ─── Storage Account — Diagnostic Settings ───────────────────────────────────
# One diagnostic setting per storage service (blob, file, table, queue).
# Captures read/write/delete operations and transaction metrics for audit
# and troubleshooting.

locals {
  storage_services = {
    blob  = "blobServices/default"
    file  = "fileServices/default"
    table = "tableServices/default"
    queue = "queueServices/default"
  }
}

resource "azurerm_monitor_diagnostic_setting" "storage" {
  for_each = local.storage_services

  name                       = "diag-st-${local.stamp_prefix}-${each.key}"
  target_resource_id         = "${azurerm_storage_account.this.id}/${each.value}"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  metric {
    category = "Transaction"
  }
}
