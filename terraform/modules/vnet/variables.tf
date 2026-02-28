variable "name" {
  type        = string
  description = "VNet name."
}

variable "resource_group_name" {
  type        = string
  description = "Target resource group."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "address_space" {
  type        = list(string)
  description = "VNet address space CIDR(s)."
}

variable "subnets" {
  type = list(object({
    name                              = string
    address_prefixes                  = list(string)
    delegation                        = optional(string)
    service_endpoints                 = optional(list(string), [])
    private_endpoint_network_policies = optional(string, "Disabled")
  }))
  description = "List of subnet definition objects. One NSG is created per subnet and associated automatically."
}

variable "attach_nat_gateway" {
  type        = bool
  default     = false
  description = "When true, all subnets in this VNet are associated with var.nat_gateway_id."
}

variable "nat_gateway_id" {
  type        = string
  default     = null
  description = "NAT Gateway resource ID. Required when attach_nat_gateway is true."
}

variable "private_dns_zones" {
  type        = map(string)
  default     = {}
  description = "Map of Private DNS Zone name → resource ID to link to this VNet. Keys must be static zone name strings (e.g. 'privatelink.vaultcore.azure.net'); values are the zone resource IDs (apply-time). Using static keys avoids the Terraform for_each limitation where set/map keys must be known at plan time."
}

variable "flow_logs_enabled" {
  type        = bool
  default     = false
  description = "When true, NSG flow logs with Traffic Analytics are created for every subnet NSG. Requires log_analytics_workspace_id, log_analytics_workspace_guid, and flow_log_storage_account_id to be set."
}

variable "log_analytics_workspace_id" {
  type        = string
  default     = null
  description = "Log Analytics Workspace resource ID (full Azure resource ID). Required when flow_logs_enabled is true."
}

variable "log_analytics_workspace_guid" {
  type        = string
  default     = null
  description = "Log Analytics Workspace GUID (the workspace_id property on the azurerm_log_analytics_workspace resource). Required for NSG flow log Traffic Analytics."
}

variable "flow_log_storage_account_id" {
  type        = string
  default     = null
  description = "Storage Account ID for NSG flow log raw blob storage. Required when flow logs are enabled."
}

variable "network_watcher_name" {
  type        = string
  default     = null
  description = "Name of the Network Watcher. Defaults to NetworkWatcher_{location} (the Azure-managed convention)."
}

variable "network_watcher_resource_group_name" {
  type        = string
  default     = "NetworkWatcherRG"
  description = "Resource group of the Network Watcher. Defaults to NetworkWatcherRG."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Resource tags applied to all resources in this module."
}
