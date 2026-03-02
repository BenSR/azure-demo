# ─── TLS Secrets — Key Vault ──────────────────────────────────────────────────
# Writes the certificates generated in phase1/core into each stamp's Key Vault.
# Phase 2 runs on the VNet-injected runner so it can reach the KV Private
# Endpoints directly — this would be denied from a public GitHub-hosted runner.
#
# Three secrets are written per stamp:
#
#   ca-cert-pem     — CA public certificate (PEM).  Callers and services use
#                     this to verify certificates signed by the internal CA.
#
#   client-cert-pem — Client certificate (PEM) signed by the CA.  Callers
#                     present this certificate when authenticating with APIM
#                     (mTLS inbound policy).
#
#   client-key-pem  — Client certificate private key (PEM).  Paired with the
#                     client cert.  Access is restricted via Key Vault RBAC to
#                     the roles assigned in phase1/env (KV Secrets User).
#
# The Key Vault RBAC assignments (CI/CD SP → KV Secrets Officer, APIM MI →
# KV Certificate User) are made in the workload-stamp module in phase1/env,
# so no additional role assignments are required here.

resource "azurerm_key_vault_secret" "ca_cert" {
  for_each = local.stamps_map

  name         = "ca-cert-pem"
  value        = local.core.ca_cert_pem
  key_vault_id = local.env.key_vault_ids[each.key]
  content_type = "application/x-pem-file"

  tags = local.tags
}

resource "azurerm_key_vault_secret" "client_cert" {
  for_each = local.stamps_map

  name         = "client-cert-pem"
  value        = local.core.client_cert_pem
  key_vault_id = local.env.key_vault_ids[each.key]
  content_type = "application/x-pem-file"

  tags = local.tags
}

resource "azurerm_key_vault_secret" "client_key" {
  for_each = local.stamps_map

  name         = "client-key-pem"
  value        = local.core.client_private_key_pem
  key_vault_id = local.env.key_vault_ids[each.key]
  content_type = "application/x-pem-file"

  tags = local.tags
}

# ─── Deployment Webhook URL — Key Vault ───────────────────────────────────────
# The Kudu container deployment webhook URL triggers the Function App to pull
# the updated image and restart — without requiring a Terraform apply.
#
# Why KV and not a plain output: the URL embeds publishing credentials
# (site_credential username + password) and must be treated as a secret.
#
# Why stored here (Phase 2) not in the workload-stamp module: the stamp KV has
# public_network_access_enabled = false.  Phase 1 applies from a public hosted
# runner that cannot reach the KV data plane.  Phase 2 runs on the VNet-injected
# runner in snet-runner, which can reach the KV Private Endpoint.
#
# CI/CD flow (see docs/3_cicd_approach.md):
#   1. VNet runner pushes new image to ACR.
#   2. VNet runner reads this secret from KV: az keyvault secret show ...
#   3. VNet runner POSTs to the webhook URL → Function App pulls image + restarts.

resource "azurerm_key_vault_secret" "func_deploy_webhook" {
  for_each = local.stamps_map

  name         = "deploy-webhook-url"
  value        = one(values(local.env.function_app_webhook_urls[each.key]))
  key_vault_id = local.env.key_vault_ids[each.key]
  content_type = "text/plain"

  tags = local.tags
}
