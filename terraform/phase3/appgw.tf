# ═══════════════════════════════════════════════════════════════════════════════
# Application Gateway v2 — Public ingress with mTLS
#
# Provides a public HTTPS endpoint that terminates TLS (including mTLS client
# certificate validation) and routes requests to the internal APIM instances
# based on URL path.
#
# Traffic flow:
#
#   Client ──HTTPS+mTLS──► App GW ──HTTP──► APIM ──HTTPS+MI──► Function App
#                          (public)        (VNet-internal)       (PE)
#
# Path-based routing:
#   /api/dev/*   → pool-apim-dev  (rewrite strips /dev)
#   /api/prod/*  → pool-apim-prod (rewrite strips /prod)
#
# Backend communication uses HTTP (port 80) to APIM within the VNet.
# This avoids the complexity of trusting APIM's default self-signed cert.
# NSGs restrict App GW → APIM traffic to port 80 from snet-appgw only.
#
# PRODUCTION NOTE: For end-to-end TLS, configure a custom domain on APIM
# with a certificate signed by the project CA, then switch the backend to
# HTTPS and add the CA cert as a trusted_root_certificate on the App GW.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Public IP ────────────────────────────────────────────────────────────────
# Standard SKU static IP required for Application Gateway v2.

resource "azurerm_public_ip" "appgw" {
  name                = "pip-appgw-${local.name_suffix}"
  resource_group_name = local.core.resource_group_core
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# ─── Application Gateway ─────────────────────────────────────────────────────

resource "azurerm_application_gateway" "this" {
  name                = "appgw-${local.name_suffix}"
  resource_group_name = local.core.resource_group_core
  location            = var.location

  # ── SKU & scaling ──────────────────────────────────────────────────────────
  # Standard_v2 is sufficient for the assessment.  Use WAF_v2 in production
  # for Azure Web Application Firewall capabilities.

  sku {
    name = var.appgw_sku
    tier = var.appgw_sku
  }

  autoscale_configuration {
    min_capacity = var.appgw_min_capacity
    max_capacity = var.appgw_max_capacity
  }

  # ── Identity ───────────────────────────────────────────────────────────────
  # User-Assigned MI for Key Vault certificate access.

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw.id]
  }

  # ── Gateway IP configuration ───────────────────────────────────────────────

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  # ── Frontend ───────────────────────────────────────────────────────────────

  frontend_ip_configuration {
    name                 = "frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  # ── TLS — Server certificate ───────────────────────────────────────────────
  # Self-signed cert from Key Vault.  Versionless secret ID allows auto-renewal.

  ssl_certificate {
    name                = "appgw-server-cert"
    key_vault_secret_id = azurerm_key_vault_certificate.server.versionless_secret_id
  }

  # ── TLS — Trusted client CA (mTLS) ─────────────────────────────────────────
  # The CA certificate generated in phase1/core.  Clients must present a
  # certificate signed by this CA.

  trusted_client_certificate {
    name = "ca-cert"
    data = nonsensitive(base64encode(local.core.ca_cert_pem))
  }

  # ── TLS — SSL profile (mTLS enforcement) ───────────────────────────────────
  # Binds the trusted CA to the HTTPS listener.  Every client request must
  # present a valid certificate signed by the CA.  Self-signed CA means no
  # CRL/OCSP checking is possible.

  ssl_profile {
    name                             = "mtls-profile"
    trusted_client_certificate_names = ["ca-cert"]

    verify_client_cert_issuer_dn = false
    # verify_client_certificate_revocation omitted — defaults to no revocation
    # checking, which is correct for self-signed CA certs (no CRL/OCSP).

    ssl_policy {
      policy_type = "Predefined"
      policy_name = "AppGwSslPolicy20220101"
    }
  }

  # ── TLS — Global SSL policy ────────────────────────────────────────────────

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # ── Backend address pools — one per environment ─────────────────────────────
  # Each pool contains the APIM FQDN for that environment.  DNS resolves to
  # the APIM private IP via the azure-api.net Private DNS Zone.

  dynamic "backend_address_pool" {
    for_each = toset(var.environments)
    content {
      name  = "pool-apim-${backend_address_pool.key}"
      fqdns = [local.env_apim_hostnames[backend_address_pool.key]]
    }
  }

  # ── Backend HTTP settings — one per environment ─────────────────────────────
  # HTTP (port 80) to APIM.  pick_host_name_from_backend_address ensures the
  # Host header matches the APIM FQDN so APIM routes correctly.

  dynamic "backend_http_settings" {
    for_each = toset(var.environments)
    content {
      name                                = "apim-http-${backend_http_settings.key}"
      cookie_based_affinity               = "Disabled"
      port                                = 80
      protocol                            = "Http"
      request_timeout                     = 30
      probe_name                          = "probe-apim-${backend_http_settings.key}"
      pick_host_name_from_backend_address = true
    }
  }

  # ── Health probes — one per environment ─────────────────────────────────────
  # HTTP GET to the APIM health endpoint.  This traverses the APIM
  # health-check operation which bypasses mTLS and MI auth (configured in
  # phase2/env/apim-config.tf).

  dynamic "probe" {
    for_each = toset(var.environments)
    content {
      name                = "probe-apim-${probe.key}"
      protocol            = "Http"
      host                = local.env_apim_hostnames[probe.key]
      path                = "/api/health"
      interval            = 30
      timeout             = 30
      unhealthy_threshold = 3

      match {
        status_code = ["200-399"]
      }
    }
  }

  # ── HTTPS listener (mTLS) ──────────────────────────────────────────────────
  # Single listener for all environments — URL path map routes to the correct
  # backend.  The SSL profile enforces client certificate presentation.

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend-ip"
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    ssl_certificate_name           = "appgw-server-cert"
    ssl_profile_name               = "mtls-profile"
  }

  # ── URL path map — route by environment ─────────────────────────────────────
  # /api/dev/*  → pool-apim-dev  + rewrite-dev  (strips /dev)
  # /api/prod/* → pool-apim-prod + rewrite-prod (strips /prod)
  # Default → first environment (catches unmatched paths).

  url_path_map {
    name                               = "api-routing"
    default_backend_address_pool_name  = "pool-apim-${var.environments[0]}"
    default_backend_http_settings_name = "apim-http-${var.environments[0]}"
    default_rewrite_rule_set_name      = "rewrite-${var.environments[0]}"

    dynamic "path_rule" {
      for_each = toset(var.environments)
      content {
        name                       = "route-${path_rule.key}"
        paths                      = ["/api/${path_rule.key}/*"]
        backend_address_pool_name  = "pool-apim-${path_rule.key}"
        backend_http_settings_name = "apim-http-${path_rule.key}"
        rewrite_rule_set_name      = "rewrite-${path_rule.key}"
      }
    }
  }

  # ── Rewrite rule sets — strip environment prefix from URL path ──────────────
  # The App Gateway receives /api/<env>/<operation> and forwards to APIM as
  # /api/<operation>.  Example:
  #   /api/dev/message  → /api/message
  #   /api/prod/health  → /api/health

  dynamic "rewrite_rule_set" {
    for_each = toset(var.environments)
    content {
      name = "rewrite-${rewrite_rule_set.key}"

      rewrite_rule {
        name          = "strip-${rewrite_rule_set.key}-prefix"
        rule_sequence = 100

        condition {
          variable    = "var_uri_path"
          pattern     = "/api/${rewrite_rule_set.key}/(.*)"
          ignore_case = true
          negate      = false
        }

        url {
          path       = "/api/{var_uri_path_1}"
          components = "path_only"
          reroute    = false
        }
      }
    }
  }

  # ── Request routing rule ────────────────────────────────────────────────────
  # Path-based routing via the URL path map above.

  request_routing_rule {
    name               = "api-rule"
    priority           = 100
    rule_type          = "PathBasedRouting"
    http_listener_name = "https-listener"
    url_path_map_name  = "api-routing"
  }

  tags = local.tags

  depends_on = [
    azurerm_key_vault_certificate.server,
    azurerm_private_endpoint.kv,
    azurerm_role_assignment.appgw_kv_secrets,
    azurerm_subnet_network_security_group_association.appgw,
  ]
}
