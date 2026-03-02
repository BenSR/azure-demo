# ─── APIM Gateway TLS Certificate ─────────────────────────────────────────────
# Signs a TLS certificate for the APIM custom gateway hostname using the
# project CA generated in phase1/core.  Application Gateway trusts this CA
# and uses it to verify the backend connection — giving us end-to-end TLS
# without needing a separate Key Vault or CA from a public PKI.
#
# We use a custom domain (internal.contoso.com) instead of the default
# azure-api.net FQDN.  This avoids the need for a broad azure-api.net Private
# DNS Zone which would intercept management/SCM endpoint resolution and break
# both the runner (Terraform provider 422) and APIM's own health checks.
#
# The certificate is embedded directly in hostname_configuration as a PFX so
# no additional Key Vault access policies are required.

locals {
  apim_custom_hostname = "apim-${local.name_suffix}.internal.contoso.com"
}

resource "tls_private_key" "apim_gw" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "apim_gw" {
  private_key_pem = tls_private_key.apim_gw.private_key_pem

  subject {
    common_name  = local.apim_custom_hostname
    organization = "Core Platform"
  }

  dns_names = [local.apim_custom_hostname]
}

resource "tls_locally_signed_cert" "apim_gw" {
  cert_request_pem   = tls_cert_request.apim_gw.cert_request_pem
  ca_private_key_pem = local.core.ca_private_key_pem
  ca_cert_pem        = local.core.ca_cert_pem

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "server_auth",
    "digital_signature",
    "key_encipherment",
  ]
}

resource "pkcs12_from_pem" "apim_gw" {
  password        = ""
  cert_pem        = tls_locally_signed_cert.apim_gw.cert_pem
  private_key_pem = tls_private_key.apim_gw.private_key_pem
}

# ─── API Management ───────────────────────────────────────────────────────────
# Developer tier in Internal VNet mode.
# Internal mode means the gateway is reachable only from within the VNet;
# there is no public endpoint.
#
# The default *.azure-api.net hostname is left intact (no Private DNS Zone
# intercepts it), so Azure's management plane, SCM, and health probes resolve
# via public DNS and continue to work.  The custom hostname below is the one
# used by Application Gateway and internal callers.
#
# NOTE: The NSG rules required for APIM to provision (apim_in_allow_mgmt,
# apim_in_allow_lb_health, apim_in_allow_lb_https) are applied by
# phase1/core and are guaranteed to exist before this root module runs.

resource "azurerm_api_management" "this" {
  name                = "apim-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.location
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email

  sku_name = "Developer_1"

  # Internal VNet mode — APIM is not reachable from the public internet.
  virtual_network_type = "Internal"

  virtual_network_configuration {
    subnet_id = local.core.subnet_ids["snet-apim"]
  }

  # System-assigned MI used in Phase 3 to retrieve mTLS certs from Key Vault.
  identity {
    type = "SystemAssigned"
  }

  # ── TLS — Gateway hostname certificate ────────────────────────────────────
  # Adds a custom gateway hostname with a CA-signed cert so Application
  # Gateway can establish an HTTPS backend connection and verify the cert
  # against the project CA.  The default *.azure-api.net hostname remains
  # active for Azure's own management traffic.
  # Changing this triggers a full APIM re-provision (~30-45 min).

  hostname_configuration {
    proxy {
      host_name           = local.apim_custom_hostname
      certificate         = pkcs12_from_pem.apim_gw.result
      default_ssl_binding = true
    }
  }

  tags = local.tags
}

# ─── APIM — Private DNS A record ──────────────────────────────────────────────
# Points the custom gateway hostname to APIM's private IP.
# The internal.contoso.com zone is scoped only to our custom domain, so the
# default *.azure-api.net management/SCM FQDNs resolve via public DNS — no
# more Catch-22 with runner connectivity or APIM self-health checks.

resource "azurerm_private_dns_a_record" "apim_gateway" {
  name                = "apim-${local.name_suffix}"
  zone_name           = "internal.contoso.com"
  resource_group_name = local.core.resource_group_core
  ttl                 = 300
  records             = [tolist(azurerm_api_management.this.private_ip_addresses)[0]]
}

# ─── APIM — diagnostic settings ───────────────────────────────────────────────
resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "diag-apim-${local.name_suffix}"
  target_resource_id         = azurerm_api_management.this.id
  log_analytics_workspace_id = local.core.log_analytics_workspace_id

  enabled_log {
    category = "GatewayLogs"
  }

  enabled_log {
    category = "WebSocketConnectionLogs"
  }
}
