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

  description             = "Stamp ${each.key} (${local.environment}): HTTP 5xx response detected in Application Insights requests table"
  severity                = 2
  evaluation_frequency    = "PT5M"
  window_duration         = "PT5M"
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

# ─── App Insights — Standard Web Test (Availability Probe) ─────────────────────
# Synthetic availability test that probes the Function App health endpoint via
# the APIM gateway from multiple Azure-managed geo-locations.  Populates the
# availabilityResults metric consumed by the func_availability alert below.
#
# One web test per stamp, scoped to that stamp's Application Insights instance.
# The primary stamp is used as the backend for the health endpoint in the APIM
# policy (health-check operation routes to stamp-index 0 — see apim-config.tf).
# Each stamp still gets its own web test to confirm App Insights metric linkage.
#
# NOTE (private architecture): APIM is deployed in Internal VNet mode and has
# no public endpoint.  The standard web test probes originate from Microsoft-
# managed public IPs that cannot reach the APIM gateway.  In this fully private
# deployment, the web test will report failures (100% unavailability from
# external probes) — which is the expected and correct behaviour: it confirms
# that the API is NOT publicly accessible.
#
# For production environments that require in-VNet synthetic monitoring:
#   • Deploy Application Gateway with a public IP in front of APIM, OR
#   • Use TrackAvailability SDK from a VNet-hosted Function to report custom
#     availability telemetry from inside the VNet.
#
# The web test is created but disabled by default (var.web_test_enabled).
# Enable it when a public path to the APIM gateway exists.

resource "azurerm_application_insights_standard_web_test" "health" {
  for_each = local.stamps_map

  name                    = "webtest-health-stamp-${each.key}-${local.environment}"
  resource_group_name     = local.env.resource_group_stamps[each.key]
  location                = var.location
  application_insights_id = local.env.app_insights_ids[each.key]
  frequency               = var.web_test_frequency_seconds
  timeout                 = var.web_test_timeout_seconds
  enabled                 = var.web_test_enabled

  geo_locations = var.web_test_geo_locations

  request {
    url = "${local.env.apim_gateway_url}/${azurerm_api_management_api.wkld.path}/health"
  }

  validation_rules {
    expected_status_code = 200

    content {
      content_match      = "healthy"
      pass_if_text_found = true
    }
  }

  tags = local.tags
}

# ─── Metric Alert — Function App Availability ─────────────────────────────────
# Triggers when the availability percentage reported by Application Insights
# drops below the configured threshold.  This metric is populated by the
# standard web test above (when enabled) and by any other availability
# telemetry reported via the TrackAvailability SDK.

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
