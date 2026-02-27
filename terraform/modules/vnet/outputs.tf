output "vnet_id" {
  value       = azurerm_virtual_network.this.id
  description = "VNet resource ID."
}

output "vnet_name" {
  value       = azurerm_virtual_network.this.name
  description = "VNet name."
}

output "subnet_ids" {
  value       = { for k, v in azurerm_subnet.this : k => v.id }
  description = "Map of subnet name → subnet resource ID."
}

output "nsg_ids" {
  value       = { for k, v in azurerm_network_security_group.this : k => v.id }
  description = "Map of subnet name → NSG resource ID."
}

output "nsg_names" {
  value       = { for k, v in azurerm_network_security_group.this : k => v.name }
  description = "Map of subnet name → NSG name."
}
