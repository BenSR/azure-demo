output "pe_subnet_id" {
  value       = azurerm_subnet.pe.id
  description = "Resource ID of the Private Endpoints subnet."
}

output "asp_subnet_id" {
  value       = azurerm_subnet.asp.id
  description = "Resource ID of the App Service Plan VNet-integration subnet."
}

output "pe_nsg_id" {
  value       = azurerm_network_security_group.pe.id
  description = "Resource ID of the PE subnet NSG."
}

output "pe_nsg_name" {
  value       = azurerm_network_security_group.pe.name
  description = "Name of the PE subnet NSG."
}

output "asp_nsg_id" {
  value       = azurerm_network_security_group.asp.id
  description = "Resource ID of the ASP subnet NSG."
}

output "asp_nsg_name" {
  value       = azurerm_network_security_group.asp.name
  description = "Name of the ASP subnet NSG."
}
