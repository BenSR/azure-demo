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
# the backend is selected in the policy (see wkld-api-policy below).
# Extend with a backend pool or routing header for active multi-stamp traffic.

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
# Operations are driven by var.api_operations so they can be overridden per
# environment without changing the Terraform source.

resource "azurerm_api_management_api_operation" "wkld" {
  for_each = { for op in var.api_operations : op.operation_id => op }

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

# ─── APIM — API Policy (mTLS inbound + MI auth + backend routing) ─────────────
# Inbound pipeline:
#   1. validate-client-certificate — enforces mTLS; rejects any caller that
#      does not present the client certificate identified by the Named Value
#      thumbprint.  validate-trust and validate-revocation are disabled
#      (self-signed CA in assessment; enable for production PKI).
#   2. authentication-managed-identity — acquires a short-lived Entra ID JWT
#      scoped to the primary stamp's app registration (created in phase1/env).
#      APIM's system-assigned Managed Identity is the requester; no shared
#      secret is needed (Section 12.5, app-planning.md).
#   3. set-header Authorization — attaches the Bearer token so the Function
#      App's EasyAuth middleware can validate the caller's identity before any
#      function code runs.
#   4. set-backend-service — routes to the primary stamp backend (stamp 1 by
#      default).  For active multi-stamp routing, replace with a backend pool
#      or a choose/when block that selects the backend based on a request header.
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
# NOTE: The Entra app registration (identifier_uri) is created in phase1/env.
# The identifier_uri is deterministic — constructed from workload + stamp + env —
# so phase3 constructs it from locals rather than reading remote state.

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
          certificate-is-required="true">
          <identities>
            <identity
              validate-thumbprint="true"
              thumbprint="{{${azurerm_api_management_named_value.client_cert_thumbprint.name}}}" />
          </identities>
        </validate-client-certificate>
        <!--
          Managed Identity auth: acquire a short-lived Entra ID JWT scoped to
          the primary stamp's app registration.  The Function App's EasyAuth
          middleware validates this token before any function code runs.
          resource = identifier_uri of the Entra app registration, constructed
          deterministically as api://func-<workload>-<stamp>-api-<env>.
          The registration itself is created in phase1/env/entra.tf.
        -->
        <authentication-managed-identity
          resource="api://func-${local.workload}-${local.primary_stamp_key}-api-${local.environment}"
          output-token-variable-name="msi-access-token" />
        <set-header name="Authorization" exists-action="override">
          <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
        </set-header>
        <!-- Route to the primary stamp backend. -->
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
