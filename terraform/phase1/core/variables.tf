# ─── Provider / subscription ─────────────────────────────────────────────────

variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID. Set via ARM_SUBSCRIPTION_ID env var in CI."
}

variable "tenant_id" {
  type        = string
  description = "Azure Tenant (Directory) ID. Set via ARM_TENANT_ID env var in CI."
}

# ─── Placement ───────────────────────────────────────────────────────────────

variable "location" {
  type        = string
  description = "Primary Azure region for all resources (e.g. uksouth, eastus2)."
}

# ─── Workload stamp subnets ───────────────────────────────────────────────────
# core/ creates a pair of VNet subnets (PE + ASP) and matching NSG rules for
# each stamp entry.  Each stamp specifies an environment and a numeric stamp
# name; the combination must be unique.  CIDRs must fall within
# vnet_address_space.

variable "stamp_subnets" {
  type = list(object({
    environment     = string
    stamp_name      = string
    subnet_pe_cidr  = string
    subnet_asp_cidr = string
  }))
  description = "List of stamp subnet definitions. Each entry produces a PE + ASP subnet pair named snet-stamp-<env>-<stamp_name>-pe/asp."

  validation {
    condition     = length(var.stamp_subnets) >= 1
    error_message = "At least one stamp must be defined."
  }

  validation {
    condition     = alltrue([for v in var.stamp_subnets : can(tonumber(v.stamp_name))])
    error_message = "stamp_name must be a numeric string (e.g. \"1\", \"2\")."
  }

  validation {
    condition = length(var.stamp_subnets) == length(distinct([
      for v in var.stamp_subnets : "${v.environment}-${v.stamp_name}"
    ]))
    error_message = "Each environment + stamp_name combination must be unique."
  }
}

# ─── Jump box ─────────────────────────────────────────────────────────────────

variable "jumpbox_admin_username" {
  type        = string
  description = "Local administrator username for the jump box VM."
  default     = "azureadmin"
}

variable "jumpbox_vm_size" {
  type        = string
  description = "VM size for the jump box."
  default     = "Standard_B2s"
}
