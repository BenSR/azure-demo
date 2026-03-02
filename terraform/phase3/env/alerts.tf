# ─── Monitor Action Group ─────────────────────────────────────────────────────
# Shared action group for all alert rules in this environment.
# Email receivers are driven by var.alert_email_receivers so the list can
# vary between dev/test/prod without changing source.

resource "azurerm_monitor_action_group" "wkld" {
  name                = "ag-wkld-${local.environment}"
  resource_group_name = local.env.resource_group_shared
  short_name          = "wkld-${substr(local.environment, 0, 8)}"

  dynamic "email_receiver" {
    for_each = { for idx, addr in var.alert_email_receivers : tostring(idx) => addr }
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.tags
}

# ─── Metric Alert — Function App Request Failures ─────────────────────────────
# One alert rule per stamp, scoped to the stamp's Application Insights instance.
# Triggers when the count of failed requests in the evaluation window exceeds
# the configured threshold.
#
# Metric: microsoft.insights/components — requests/failed
#   Counts requests that the Function App runtime marked as failed (typically
#   5xx responses and unhandled exceptions).  The alert fires based on
#   var.alert_5xx_failure_threshold (count, not a percentage) over a
#   var.alert_5xx_window_minutes evaluation window.

resource "azurerm_monitor_metric_alert" "func_failures" {
  for_each = local.stamps_map

  name                = "alert-func-failures-stamp-${each.key}-${local.environment}"
  resource_group_name = local.env.resource_group_stamps[each.key]
  description         = "Stamp ${each.key} (${local.environment}): Function App request failures exceeded threshold"
  severity            = 2 # Warning
  frequency           = "PT5M"
  window_size         = "PT${var.alert_5xx_window_minutes}M"
  auto_mitigate       = true

  scopes = [local.env.app_insights_ids[each.key]]

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/failed"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = var.alert_5xx_failure_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.wkld.id
  }

  tags = local.tags
}

# ─── Scheduled Query Alert — HTTP 5xx Responses ───────────────────────────────
# Queries the Application Insights requests table directly so the alert fires
# on any HTTP 5xx response, regardless of whether the Functions runtime also
# raises an exception.  This is more reliable than the metric-based
# requests/failed alert for deliberately-returned 500s (no exception raised).
#
# Scope: Application Insights resource (workspace-based).  The KQL query runs
# in the context of the App Insights resource and has access to the requests,
# traces, exceptions, and dependencies tables.

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "func_5xx_query" {
  for_each = local.stamps_map

  name                = "sqr-func-5xx-stamp-${each.key}-${local.environment}"
  resource_group_name = local.env.resource_group_stamps[each.key]
  location            = var.location

  description          = "Stamp ${each.key} (${local.environment}): HTTP 5xx response detected in Application Insights requests table"
  severity             = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  auto_mitigation_enabled = true

  scopes = [local.env.app_insights_ids[each.key]]

  criteria {
    query                   = "requests | where resultCode startswith \"5\""
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.wkld.id]
  }

  tags = local.tags
}

# ─── Metric Alert — Function App Availability ─────────────────────────────────
# Triggers when the availability percentage reported by Application Insights
# drops below the configured threshold.  This metric is populated by the
# Function App runtime telemetry (health-check requests) and by any synthetic
# monitor requests that hit the endpoint.
#
# NOTE: For a fully private deployment (APIM in Internal mode, Function Apps
# behind Private Endpoints) the availability metric is driven by internal
# traffic only.  Consider adding a custom synthetic heartbeat triggered by
# the VNet-injected runner or an Azure Private Test to populate this metric
# with proactive probe data.

resource "azurerm_monitor_metric_alert" "func_availability" {
  for_each = local.stamps_map

  name                = "alert-func-availability-stamp-${each.key}-${local.environment}"
  resource_group_name = local.env.resource_group_stamps[each.key]
  description         = "Stamp ${each.key} (${local.environment}): Function App availability dropped below threshold"
  severity            = 1 # Error
  frequency           = "PT5M"
  window_size         = "PT15M"
  auto_mitigate       = true

  scopes = [local.env.app_insights_ids[each.key]]

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "availabilityResults/availabilityPercentage"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = var.alert_availability_threshold_percent
  }

  action {
    action_group_id = azurerm_monitor_action_group.wkld.id
  }

  tags = local.tags
}
