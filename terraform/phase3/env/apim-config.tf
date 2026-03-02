# ─── APIM — Load-balancing policy helper ──────────────────────────────────────
# Generates one <when> block per stamp for use inside the <choose> element of
# the inbound policy.  Each block:
#   1. Acquires an Entra MI token scoped to that stamp's app registration.
#   2. Attaches it as a Bearer Authorization header.
#   3. Routes the request to that stamp's APIM backend.
#
# Stamps are sorted by stamp_name so the index used in the Random.Next()
# condition is stable across plan/apply cycles.

locals {
  api_operations = [
    {
      operation_id = "health-check"
      display_name = "Health Check"
      http_method  = "GET"
      url_template = "/health"
    },
    {
      operation_id = "post-message"
      display_name = "Post Message"
      http_method  = "POST"
      url_template = "/message"
    },
  ]

  _apim_lb_when_blocks = join("\n", [for i, k in local.sorted_stamp_keys :
    join("\n", [
      "        <when condition=\"@((int)context.Variables[&quot;stamp-index&quot;] == ${i})\">",
      "          <authentication-managed-identity",
      "            resource=\"api://${data.azuread_client_config.current.tenant_id}/func-${local.workload}-${k}-api-${local.environment}\"",
      "            output-token-variable-name=\"msi-access-token\" />",
      "          <set-header name=\"Authorization\" exists-action=\"override\">",
      "            <value>@(\"Bearer \" + (string)context.Variables[\"msi-access-token\"])</value>",
      "          </set-header>",
      "          <set-backend-service backend-id=\"func-backend-stamp-${k}\" />",
      "        </when>",
    ])
  ])

  _debug_api_policy_xml = <<-XML
    <policies>
      <inbound>
        <base />
        <validate-client-certificate
          validate-revocation="false"
          validate-trust="false"
          validate-not-before="true"
          validate-not-after="true"
          ignore-error="false">
          <identities>
            <identity thumbprint="{{${azurerm_api_management_named_value.client_cert_thumbprint.name}}}" />
          </identities>
        </validate-client-certificate>
        <set-variable name="stamp-index" value="@(new Random().Next(${local.stamp_count}))" />
        <choose>
${local._apim_lb_when_blocks}
        </choose>
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML
}

# ─── APIM — Named Values ──────────────────────────────────────────────────────
# Named Values expose configuration to APIM policies without hard-coding values.
# The client certificate thumbprint is used by the inbound mTLS policy to
# validate that the caller is presenting the correct client certificate.

resource "azurerm_api_management_named_value" "client_cert_thumbprint" {
  name                = "client-cert-thumbprint"
  resource_group_name = local.apim_rg
  api_management_name = local.apim_name
  display_name        = "client-cert-thumbprint"
  value               = local.client_cert_thumbprint

  # Thumbprints are not sensitive (they identify but don't authenticate),
  # but mark secret = true if your policy requires it.
  secret = false
}

# ─── APIM — Function App Backends ─────────────────────────────────────────────
# One APIM backend per stamp, pointing to the Function App's default hostname.
# DNS resolves the hostname to the Private Endpoint IP within the VNet, so
# traffic never leaves the private network.

resource "azurerm_api_management_backend" "func" {
  for_each = local.stamps_map

  name                = "func-backend-stamp-${each.key}"
  resource_group_name = local.apim_rg
  api_management_name = local.apim_name
  protocol            = "http"

  # function_app_hostnames: map of stamp → (map of func-name → default hostname)
  # One Function App per stamp; use `one(values(...))` to extract the single hostname.
  url = "https://${one(values(local.env.function_app_hostnames[each.key]))}"

  tls {
    # Function Apps use Azure-managed *.azurewebsites.net certs; the PE hostname
    # resolves to a private IP so chain/name validation is disabled to avoid
    # certificate mismatch errors on the internal endpoint.
    validate_certificate_chain = false
    validate_certificate_name  = false
  }
}

# ─── APIM — API ───────────────────────────────────────────────────────────────
# One shared API per environment.  All stamps serve the same API contract;
# the backend is selected per-request by the round-robin load-balancing policy.

resource "azurerm_api_management_api" "wkld" {
  name                  = "wkld-api-${local.environment}"
  resource_group_name   = local.apim_rg
  api_management_name   = local.apim_name
  revision              = "1"
  display_name          = "Workload API (${local.environment})"
  path                  = "api"
  protocols             = ["https"]
  subscription_required = false
}

# ─── APIM — API Operations ────────────────────────────────────────────────────

resource "azurerm_api_management_api_operation" "wkld" {
  for_each = { for op in local.api_operations : op.operation_id => op }

  operation_id        = each.key
  api_name            = azurerm_api_management_api.wkld.name
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg
  display_name        = each.value.display_name
  method              = each.value.http_method
  url_template        = each.value.url_template

  response {
    status_code = 200
    description = "Success"
  }
}

# ─── APIM — API Policy (mTLS + round-robin load balancing) ────────────────────
# Inbound pipeline:
#   1. validate-client-certificate — enforces mTLS; rejects any caller that
#      does not present the client certificate matching the Named Value
#      thumbprint.  validate-trust and validate-revocation are disabled
#      (self-signed CA in assessment; enable for production PKI).
#      ignore-error="false" ensures the request is rejected on validation failure.
#   2. set-variable stamp-index — picks a random integer in [0, stamp_count)
#      to select a backend for this request (uniform random load balancing).
#   3. choose/when — for each stamp index, acquires a short-lived Entra ID JWT
#      scoped to that stamp's app registration (created in phase1/env/entra.tf),
#      attaches it as a Bearer token, and routes to that stamp's backend.
#      Each stamp has its own app registration so the MI token resource must
#      also be selected per stamp.
#
# NOTE: The health-check operation has a separate operation-level policy that
# bypasses steps 1–3 (no mTLS, no MI auth) — see below.
#
# NOTE: APIM must have "Negotiate client certificate" enabled at the service
# level (set via the Azure portal or azurerm_api_management negotiate_client_certificate
# property once it is exposed in the provider).  This cannot currently be set
# via the azurerm provider directly for the Developer SKU; it is configured
# via the Azure portal or the Management REST API.
#
# NOTE: The Entra app registration identifier_uri is constructed deterministically
# as api://<tenant-id>/func-<workload>-<stamp>-api-<env> (same convention as phase1/env).

resource "azurerm_api_management_api_policy" "wkld" {
  api_name            = azurerm_api_management_api.wkld.name
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <!--
          mTLS: require the caller to present the provisioned client certificate.
          The {{client-cert-thumbprint}} Named Value holds the SHA-1 fingerprint
          of the certificate written to Key Vault by secrets.tf.
        -->
        <validate-client-certificate
          validate-revocation="false"
          validate-trust="false"
          validate-not-before="true"
          validate-not-after="true"
          ignore-error="false">
          <identities>
            <identity thumbprint="{{${azurerm_api_management_named_value.client_cert_thumbprint.name}}}" />
          </identities>
        </validate-client-certificate>
        <!--
          Round-robin load balancing: pick a random stamp index in [0, ${local.stamp_count}).
          The choose/when blocks below acquire the correct Entra MI token and
          route to the matching backend for that stamp.
        -->
        <set-variable name="stamp-index" value="@(new Random().Next(${local.stamp_count}))" />
        <choose>
${local._apim_lb_when_blocks}
        </choose>
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML

  depends_on = [
    azurerm_api_management_backend.func,
    azurerm_api_management_named_value.client_cert_thumbprint,
  ]
}

# ─── APIM — Health Check Operation Policy ─────────────────────────────────────
# The GET /api/health endpoint is used by App Insights availability tests and
# APIM health probes.  These callers do not carry client certificates or Entra
# tokens (Section 12.6, app-planning.md).
#
# The operation-level policy intentionally omits <base /> in the inbound section
# to bypass the API-level mTLS validation and Managed Identity authentication.
# Network isolation (NSGs restrict the PE subnet to APIM-sourced traffic on
# port 443) limits the blast radius — the health endpoint returns no sensitive
# data: {"status": "healthy", "timestamp": "..."}.
#
# Health probes always target the primary stamp (stamp-index 0) to avoid
# introducing randomness into synthetic monitoring.

resource "azurerm_api_management_api_operation_policy" "health_check" {
  operation_id        = "health-check"
  api_name            = azurerm_api_management_api.wkld.name
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg

  xml_content = <<-XML
    <policies>
      <inbound>
        <!--
          No <base /> — intentionally bypasses API-level mTLS and MI auth.
          Health probes (App Insights availability tests, APIM itself) do not
          carry client certificates or Entra tokens.
        -->
        <set-backend-service
          backend-id="${azurerm_api_management_backend.func[local.primary_stamp_key].name}" />
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML

  depends_on = [
    azurerm_api_management_api_operation.wkld,
    azurerm_api_management_backend.func,
  ]
}
