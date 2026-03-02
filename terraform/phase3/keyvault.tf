# ═══════════════════════════════════════════════════════════════════════════════
# Key Vault — Application Gateway certificate storage
#
# A dedicated Key Vault for the App Gateway's TLS server certificate.
# The certificate is self-signed and generated directly in Key Vault using
# the built-in issuer ("Self"), avoiding the need for PFX conversion or
# external tools.
#
# The App Gateway accesses the certificate via a User-Assigned Managed Identity
# with Key Vault Secrets User permissions.  Key Vault is locked down with
# public_network_access_enabled = false and a Private Endpoint in snet-shared-pe.
# ═══════════════════════════════════════════════════════════════════════════════

# ─── User-Assigned Managed Identity ──────────────────────────────────────────
# Attached to the Application Gateway for Key Vault certificate reads.

resource "azurerm_user_assigned_identity" "appgw" {
  name                = "id-appgw-${local.name_suffix}"
  resource_group_name = local.core.resource_group_core
  location            = var.location
  tags                = local.tags
}

# ─── Key Vault ────────────────────────────────────────────────────────────────

resource "azurerm_key_vault" "appgw" {
  name                          = "kv-appgw-${local.name_suffix}"
  resource_group_name           = local.core.resource_group_core
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = false
  purge_protection_enabled      = false

  tags = local.tags
}

# ─── RBAC — CI/CD SP → Key Vault Administrator ───────────────────────────────
# Required so the Terraform apply (running as the CI/CD SP) can create the
# self-signed certificate in Key Vault.

resource "azurerm_role_assignment" "cicd_kv_admin" {
  scope                = azurerm_key_vault.appgw.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ─── RBAC — App GW MI → Key Vault Secrets User ───────────────────────────────
# App Gateway reads the certificate as a Key Vault secret (PFX).  Secrets User
# is sufficient; Certificate User would also work.

resource "azurerm_role_assignment" "appgw_kv_secrets" {
  scope                = azurerm_key_vault.appgw.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw.principal_id
}

# ─── Private Endpoint — Key Vault ────────────────────────────────────────────
# Placed in snet-shared-pe (same subnet as the ACR PE).  The NSG on
# snet-shared-pe already allows inbound from snet-runner (for CI/CD) and
# a new rule (see network.tf) allows inbound from snet-appgw for runtime
# certificate reads.

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-kv-appgw-${local.name_suffix}"
  resource_group_name = local.core.resource_group_core
  location            = var.location
  subnet_id           = local.core.subnet_ids["snet-shared-pe"]

  private_service_connection {
    name                           = "psc-kv-appgw-${local.name_suffix}"
    private_connection_resource_id = azurerm_key_vault.appgw.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [local.core.private_dns_zone_ids.key_vault_zone_id]
  }

  tags = local.tags
}

# ─── Diagnostic Settings ─────────────────────────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "kv_appgw" {
  name                       = "diag-kv-appgw-${local.name_suffix}"
  target_resource_id         = azurerm_key_vault.appgw.id
  log_analytics_workspace_id = local.core.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }
}

# ─── Self-signed server certificate ──────────────────────────────────────────
# Generated directly in Key Vault using the built-in "Self" issuer.  This
# avoids the need to construct a PFX file externally — Key Vault issues the
# cert as PKCS#12 natively.
#
# The App Gateway references this certificate by its versionless secret ID
# so that Key Vault auto-renewal (when configured) is picked up automatically.
#
# NOTE: This is a self-signed certificate.  Clients connecting to the App
# Gateway must either trust this cert or disable server cert validation
# (e.g. curl -k).  In production, replace with a cert from a trusted CA or
# use Azure-managed certificates with a custom domain.

resource "azurerm_key_vault_certificate" "server" {
  name         = "appgw-server-cert"
  key_vault_id = azurerm_key_vault.appgw.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = false
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=appgw-${local.name_suffix}"
      validity_in_months = 12

      key_usage = [
        "digitalSignature",
        "keyEncipherment",
      ]
    }
  }

  depends_on = [
    azurerm_role_assignment.cicd_kv_admin,
    azurerm_private_endpoint.kv,
  ]
}
