# ─── Entra ID App Registrations ───────────────────────────────────────────────
# One app registration per stamp.  Each registration acts as the token audience
# for that stamp's Function App EasyAuth — APIM acquires a JWT scoped to this
# registration's identifier_uri and the Function App's EasyAuth middleware
# validates the `aud` claim before any function code runs (Section 12.3,
# app-planning.md).
#
# Placed here (phase1/env) rather than phase2 so the client_id is available
# when the Function App is deployed — auth_settings_v2 in the workload-stamp
# module needs the client_id at apply time, before Phase 2 runs.
#
# No client secret or certificate is created — this registration receives tokens
# (it is an audience); it does not request them.

resource "azuread_application" "func_api" {
  for_each     = local.stamps_map
  display_name = "app-func-${local.workload}-${each.key}-api-${local.environment}"

  identifier_uris = [
    "api://${data.azuread_client_config.current.tenant_id}/func-${local.workload}-${each.key}-api-${local.environment}"
  ]
}

resource "azuread_service_principal" "func_api" {
  for_each  = local.stamps_map
  client_id = azuread_application.func_api[each.key].client_id
}
