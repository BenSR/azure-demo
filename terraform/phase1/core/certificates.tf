# ─── TLS Certificates (Phase 1 — generation only) ────────────────────────────
# The tls provider generates all key material locally and stores it in
# Terraform state.  Phase 3 (running on the self-hosted VNet runner) reads
# these outputs and imports them into Key Vault.
#
# Sensitive outputs are declared in outputs.tf:
#   ca_cert_pem, client_cert_pem, client_private_key_pem

# ─── Certificate Authority ────────────────────────────────────────────────────

resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  subject {
    common_name  = "core-ca"
    organization = "Core Platform"
  }

  validity_period_hours = 8760 # 1 year
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# ─── Client Certificate (signed by the CA above) ──────────────────────────────
# Used by API consumers to authenticate against APIM via mTLS.

resource "tls_private_key" "client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "client" {
  private_key_pem = tls_private_key.client.private_key_pem

  subject {
    common_name  = "core-client"
    organization = "Core Platform"
  }
}

resource "tls_locally_signed_cert" "client" {
  cert_request_pem   = tls_cert_request.client.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "client_auth",
    "digital_signature",
  ]
}

# Parse the client certificate to extract its SHA-1 fingerprint.
# Used by Phase 3 APIM mTLS validation (requires DER thumbprint).
data "tls_certificate" "client" {
  content = tls_locally_signed_cert.client.cert_pem
}
