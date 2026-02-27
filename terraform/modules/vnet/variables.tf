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
    nat_gateway_id                    = optional(string)
  }))
  description = "List of subnet definition objects. One NSG is created per subnet and associated automatically."
}

variable "private_dns_zone_ids" {
  type        = list(string)
  default     = []
  description = "List of Private DNS Zone resource IDs to link to this VNet. One VNet link is created per zone."
}

variable "log_analytics_workspace_id" {
  type        = string
  default     = null
  description = "Log Analytics Workspace resource ID (full Azure resource ID). When set alongside log_analytics_workspace_guid and flow_log_storage_account_id, NSG flow logs with Traffic Analytics are enabled for all NSGs."
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
