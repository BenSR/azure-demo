# ─── Function App — Diagnostic Settings ──────────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "function_app" {
  for_each = var.function_apps

  name                       = "diag-${each.key}"
  target_resource_id         = azurerm_linux_function_app.this[each.key].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "FunctionAppLogs"
  }

  metric {
    category = "AllMetrics"
  }
}

# ─── App Service Plan — Diagnostic Settings ───────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "app_service_plan" {
  name                       = "diag-asp-${local.stamp_prefix}"
  target_resource_id         = azurerm_service_plan.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  metric {
    category = "AllMetrics"
  }
}

# ─── Storage Account — Diagnostic Settings ────────────────────────────────────
# Diagnostic settings for storage are configured on the sub-service endpoints,
# not on the account itself.

resource "azurerm_monitor_diagnostic_setting" "storage_blob" {
  name                       = "diag-${azurerm_storage_account.this.name}-blob"
  target_resource_id         = "${azurerm_storage_account.this.id}/blobServices/default"
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

resource "azurerm_monitor_diagnostic_setting" "storage_queue" {
  name                       = "diag-${azurerm_storage_account.this.name}-queue"
  target_resource_id         = "${azurerm_storage_account.this.id}/queueServices/default"
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

resource "azurerm_monitor_diagnostic_setting" "storage_table" {
  name                       = "diag-${azurerm_storage_account.this.name}-table"
  target_resource_id         = "${azurerm_storage_account.this.id}/tableServices/default"
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
