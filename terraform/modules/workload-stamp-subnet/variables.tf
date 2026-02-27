# ─── Stamp identity ───────────────────────────────────────────────────────────

variable "environment" {
  type        = string
  description = "Environment name (e.g. \"dev\", \"test\", \"prod\"). Included in subnet and NSG names."
}

variable "stamp_name" {
  type        = string
  description = "Numeric stamp name (e.g. \"1\", \"2\"). Together with environment forms a unique identifier for this stamp."
}

variable "stamp_index" {
  type        = number
  description = "0-based index of this stamp among all stamps. Used to offset NSG rule priorities on shared NSGs so they don't collide across stamps."
}

# ─── Subnet CIDRs ────────────────────────────────────────────────────────────

variable "subnet_pe_cidr" {
  type        = string
  description = "CIDR for the Private Endpoints subnet (e.g. 10.100.0.0/24)."
}

variable "subnet_asp_cidr" {
  type        = string
  description = "CIDR for the App Service Plan VNet-integration subnet (e.g. 10.100.1.0/24)."
}

# ─── Networking context ───────────────────────────────────────────────────────

variable "vnet_name" {
  type        = string
  description = "Name of the Virtual Network where stamp subnets will be created."
}

variable "resource_group_name" {
  type        = string
  description = "Target resource group for all resources."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "nsg_name_prefix" {
  type        = string
  description = "Prefix for NSG names (e.g. 'nsg-core'). NSGs are named <prefix>-stamp-<env>-<name>-<pe|asp>."
}

# ─── Shared subnet context (for cross-cutting NSG rules) ─────────────────────

variable "shared_subnet_cidrs" {
  type = object({
    apim      = string
    shared_pe = string
    runner    = string
    jumpbox   = string
  })
  description = "CIDRs of the fixed shared subnets, referenced by cross-cutting NSG rules."
}

variable "shared_nsg_names" {
  type = object({
    apim      = string
    shared_pe = string
    runner    = string
    jumpbox   = string
  })
  description = "NSG names of the fixed shared subnets, for attaching per-stamp cross-cutting rules."
}

# ─── Flow logs ────────────────────────────────────────────────────────────────

variable "log_analytics_workspace_id" {
  type        = string
  default     = null
  description = "Log Analytics Workspace resource ID. When set (with guid + storage), NSG flow logs are enabled."
}

variable "log_analytics_workspace_guid" {
  type        = string
  default     = null
  description = "Log Analytics Workspace GUID (workspace_id property). Required for Traffic Analytics."
}

variable "flow_log_storage_account_id" {
  type        = string
  default     = null
  description = "Storage Account ID for NSG flow log raw blob storage."
}

variable "network_watcher_name" {
  type        = string
  default     = null
  description = "Name of the Network Watcher. Defaults to NetworkWatcher_{location}."
}

variable "network_watcher_resource_group_name" {
  type        = string
  default     = "NetworkWatcherRG"
  description = "Resource group of the Network Watcher."
}

# ─── Tags ─────────────────────────────────────────────────────────────────────

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Resource tags applied to all resources created by this module."
}
