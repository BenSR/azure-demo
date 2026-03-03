# ═══════════════════════════════════════════════════════════════════════════════
# Application Gateway v2 — Private ingress with mTLS via Private Link
#
# The App GW is NOT Internet-facing.  All client traffic arrives through a
# Private Endpoint (PE) in snet-shared-pe via Azure Private Link.  The PE is
# registered as appgw.internal.contoso.com in the project private DNS zone.
#
# Traffic flow:
#
#   Client ──► PE (snet-shared-pe) ──Private Link──► App GW ──HTTPS──► APIM
#              appgw.internal.contoso.com           (snet-appgw)   (VNet-internal)
#
# Path-based routing:
#   /api/dev/*   → pool-apim-dev  (rewrite strips /dev)
#   /api/prod/*  → pool-apim-prod (rewrite strips /prod)
#
# End-to-end TLS: App GW terminates the client connection (including mTLS),
# then re-establishes HTTPS to APIM.  APIM presents a certificate signed by
# the project CA (configured in phase1/env); App GW verifies it against the
# CA cert stored as trusted_root_certificate.
# NSGs restrict App GW → APIM traffic to port 443 from snet-appgw only.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Public IP ────────────────────────────────────────────────────────────────
# Standard SKU static IP required by Application Gateway v2 for management
# health probes (GatewayManager).  No listener binds to this IP — all client
# traffic enters via the Private Endpoint.

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
  # The public IP is required by AppGW v2 but no listener binds to it.
  # Private Link is attached to this frontend — PE traffic is SNATed through
  # snet-appgw-pl before reaching the gateway.

  frontend_ip_configuration {
    name                            = "frontend-ip"
    public_ip_address_id            = azurerm_public_ip.appgw.id
    private_link_configuration_name = "appgw-pl-config"
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  # ── Private Link configuration ───────────────────────────────────────────
  # Exposes the App GW frontend via Azure Private Link.  NAT IPs are allocated
  # in a dedicated subnet (snet-appgw-pl) separate from the gateway subnet.

  private_link_configuration {
    name = "appgw-pl-config"

    ip_configuration {
      name                          = "pl-ip-config"
      subnet_id                     = azurerm_subnet.appgw_pl.id
      private_ip_address_allocation = "Dynamic"
      primary                       = true
    }
  }

  # ── TLS — Server certificate ───────────────────────────────────────────────
  # Self-signed cert from Key Vault.  Versionless secret ID allows auto-renewal.

  ssl_certificate {
    name                = "appgw-server-cert"
    key_vault_secret_id = azurerm_key_vault_certificate.server.versionless_secret_id
  }

  # ── TLS — Trusted root CA (backend certificate validation) ────────────────
  # The same project CA is used to sign APIM's gateway certificate (configured
  # in phase1/env).  App GW verifies the backend cert against this CA when
  # opening the HTTPS connection to each APIM instance.

  trusted_root_certificate {
    name = "backend-ca"
    data = nonsensitive(base64encode(local.core.ca_cert_pem))
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
  # the APIM private IP via the internal.contoso.com Private DNS Zone.

  dynamic "backend_address_pool" {
    for_each = toset(var.environments)
    content {
      name  = "pool-apim-${backend_address_pool.key}"
      fqdns = [local.env_apim_hostnames[backend_address_pool.key]]
    }
  }

  # ── Backend HTTP settings — one per environment ─────────────────────────────
  # HTTPS (port 443) to APIM.  pick_host_name_from_backend_address ensures the
  # Host header matches the APIM FQDN so APIM routes to the right hostname
  # configuration.  trusted_root_certificate_names links to the CA cert so
  # App GW can verify APIM's backend certificate.

  dynamic "backend_http_settings" {
    for_each = toset(var.environments)
    content {
      name                                = "apim-https-${backend_http_settings.key}"
      cookie_based_affinity               = "Disabled"
      port                                = 443
      protocol                            = "Https"
      request_timeout                     = 30
      probe_name                          = "probe-apim-${backend_http_settings.key}"
      pick_host_name_from_backend_address = true
      trusted_root_certificate_names      = ["backend-ca"]
    }
  }

  # ── Health probes — one per environment ─────────────────────────────────────
  # HTTPS GET to the APIM health endpoint.  This traverses the APIM
  # health-check operation which bypasses mTLS and MI auth (configured in
  # phase2/env/apim-config.tf).  The host is used as the SNI name and must
  # match the CN/SAN on APIM's gateway certificate.

  dynamic "probe" {
    for_each = toset(var.environments)
    content {
      name                = "probe-apim-${probe.key}"
      protocol            = "Https"
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
    default_backend_http_settings_name = "apim-https-${var.environments[0]}"
    default_rewrite_rule_set_name      = "rewrite-${var.environments[0]}"

    dynamic "path_rule" {
      for_each = toset(var.environments)
      content {
        name                       = "route-${path_rule.key}"
        paths                      = ["/api/${path_rule.key}/*"]
        backend_address_pool_name  = "pool-apim-${path_rule.key}"
        backend_http_settings_name = "apim-https-${path_rule.key}"
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
    azurerm_subnet.appgw_pl,
  ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Private Endpoint — expose App GW via PE in snet-shared-pe
#
# Clients (jumpbox, runner) connect to the PE IP rather than the public IP.
# The PE is registered as appgw.internal.contoso.com in the project private
# DNS zone so all VNet resources resolve it automatically.
# ═══════════════════════════════════════════════════════════════════════════════

resource "azurerm_private_endpoint" "appgw" {
  name                = "pe-appgw-${local.name_suffix}"
  resource_group_name = local.core.resource_group_core
  location            = var.location
  subnet_id           = local.core.subnet_ids["snet-shared-pe"]

  private_service_connection {
    name                           = "psc-appgw-${local.name_suffix}"
    private_connection_resource_id = azurerm_application_gateway.this.id
    subresource_names              = ["frontend-ip"]
    is_manual_connection           = false
  }

  tags = local.tags
}

# ─── DNS — appgw.internal.contoso.com ──────────────────────────────────────
# A record in the internal.contoso.com zone pointing to the PE NIC IP.
# The zone is already linked to vnet-core so all subnets resolve this name.

# ─── Diagnostic Settings ─────────────────────────────────────────────────────
# Streams Application Gateway access/performance logs and Public IP DDoS
# notifications to the shared Log Analytics Workspace.

resource "azurerm_monitor_diagnostic_setting" "appgw" {
  name                       = "diag-appgw-${local.name_suffix}"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = local.core.log_analytics_workspace_id

  enabled_log {
    category = "ApplicationGatewayAccessLog"
  }

  enabled_log {
    category = "ApplicationGatewayPerformanceLog"
  }

  metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "appgw_pip" {
  name                       = "diag-pip-appgw-${local.name_suffix}"
  target_resource_id         = azurerm_public_ip.appgw.id
  log_analytics_workspace_id = local.core.log_analytics_workspace_id

  enabled_log {
    category = "DDoSProtectionNotifications"
  }

  metric {
    category = "AllMetrics"
  }
}

# ─── DNS — appgw.internal.contoso.com ──────────────────────────────────────
# A record in the internal.contoso.com zone pointing to the PE NIC IP.
# The zone is already linked to vnet-core so all subnets resolve this name.

resource "azurerm_private_dns_a_record" "appgw" {
  name                = "appgw"
  zone_name           = "internal.contoso.com"
  resource_group_name = local.core.resource_group_core
  ttl                 = 300
  records             = [azurerm_private_endpoint.appgw.private_service_connection[0].private_ip_address]
}
