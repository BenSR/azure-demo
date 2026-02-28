# ─── Resource Groups ──────────────────────────────────────────────────────────

# Per-environment shared infra — resources shared across stamps within this
# environment (currently APIM only; Key Vault has moved into each stamp).
# Naming: rg-wkld-shared-<env>

resource "azurerm_resource_group" "shared" {
  name     = "rg-${local.name_suffix}"
  location = var.location
  tags     = local.tags
}

# Per-stamp, per-environment compute — one resource group per stamp entry in
# var.stamps.  Each group holds an ASP, Function App(s), Storage Account,
# App Insights, Key Vault, and the stamp's Private Endpoints.
# Naming: rg-wkld-stamp-<N>-<env>

resource "azurerm_resource_group" "stamp" {
  for_each = local.stamps_map

  name     = "rg-${local.workload}-stamp-${each.key}-${local.environment}"
  location = each.value.location
  tags     = local.tags
}
