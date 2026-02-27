# ─── Private DNS Zones ────────────────────────────────────────────────────────
# Creates the 7 zones required for Private Endpoint FQDN resolution.
# VNet linking is handled by the vnet module (network.tf) which consumes
# module.private_dns.all_zone_ids.

module "private_dns" {
  source = "../../modules/private-dns"

  resource_group_name = azurerm_resource_group.core.name
  tags                = local.tags
}
