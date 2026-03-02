# ─── Remote state ────────────────────────────────────────────────────────────

variable "state_storage_account_name" {
  type        = string
  description = "Name of the storage account holding Terraform state (in rg-core-deploy). Used to read phase1/core and phase1/env remote state."
}

# ─── Placement ───────────────────────────────────────────────────────────────

variable "location" {
  type        = string
  default     = "northeurope"
  description = "Azure region for Application Gateway and supporting resources."
}

# ─── Environments ─────────────────────────────────────────────────────────────
# Each environment gets a backend pool, health probe, and URL path rule on the
# Application Gateway.  Must match the workspaces deployed by phase1/env.

variable "environments" {
  type        = list(string)
  default     = ["dev", "prod"]
  description = "List of environment names to route to.  Each must have a matching phase1/env workspace with APIM deployed."

  validation {
    condition     = length(var.environments) >= 1
    error_message = "At least one environment must be specified."
  }

  validation {
    condition     = length(var.environments) == length(distinct(var.environments))
    error_message = "Environment names must be unique."
  }
}

# ─── Networking ───────────────────────────────────────────────────────────────

variable "appgw_subnet_cidr" {
  type        = string
  default     = "10.100.131.0/27"
  description = "CIDR block for the Application Gateway subnet within vnet-core.  /27 minimum recommended."

  validation {
    condition     = can(cidrhost(var.appgw_subnet_cidr, 0))
    error_message = "Must be a valid CIDR block."
  }
}

variable "appgw_pl_subnet_cidr" {
  type        = string
  default     = "10.100.131.32/28"
  description = "CIDR block for the Application Gateway Private Link NAT subnet.  Must be separate from the AppGW subnet."

  validation {
    condition     = can(cidrhost(var.appgw_pl_subnet_cidr, 0))
    error_message = "Must be a valid CIDR block."
  }
}

# ─── Application Gateway ─────────────────────────────────────────────────────

variable "appgw_sku" {
  type        = string
  default     = "Standard_v2"
  description = "SKU name for the Application Gateway.  Use WAF_v2 in production for web application firewall capabilities."

  validation {
    condition     = contains(["Standard_v2", "WAF_v2"], var.appgw_sku)
    error_message = "Must be Standard_v2 or WAF_v2."
  }
}

variable "appgw_min_capacity" {
  type        = number
  default     = 1
  description = "Minimum autoscale capacity (instances).  1 is the minimum for Standard_v2."

  validation {
    condition     = var.appgw_min_capacity >= 0 && var.appgw_min_capacity <= 125
    error_message = "Must be between 0 and 125."
  }
}

variable "appgw_max_capacity" {
  type        = number
  default     = 2
  description = "Maximum autoscale capacity (instances).  Keep low for assessment cost control."

  validation {
    condition     = var.appgw_max_capacity >= 1 && var.appgw_max_capacity <= 125
    error_message = "Must be between 1 and 125."
  }
}
