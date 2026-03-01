
variable "location" {
  type        = string
  description = "Primary Azure region for all resources (e.g. uksouth, eastus2)."
}

# ─── Remote state ────────────────────────────────────────────────────────────

variable "state_storage_account_name" {
  type        = string
  description = "Name of the storage account holding Terraform state (in rg-core-deploy). Used to read phase1/core remote state."
}

# ─── Workload stamps ─────────────────────────────────────────────────────────
# Each entry deploys one workload stamp.  The combination of stamp_name +
# environment (from the Terraform workspace) must have a matching subnet pair
# in phase1/core (snet-stamp-<env>-<stamp_name>-pe / -asp).

variable "stamps" {
  type = list(object({
    stamp_name = string
    location   = string
    image_name = string
    image_tag  = optional(string, "latest")
  }))
  description = "List of workload stamps to deploy in this environment."

  validation {
    condition     = length(var.stamps) >= 1
    error_message = "At least one stamp must be defined."
  }

  validation {
    condition     = alltrue([for s in var.stamps : can(tonumber(s.stamp_name))])
    error_message = "stamp_name must be a numeric string (e.g. \"1\", \"2\")."
  }

  validation {
    condition     = length(var.stamps) == length(distinct([for s in var.stamps : s.stamp_name]))
    error_message = "Each stamp_name must be unique within the environment."
  }
}

# ─── APIM ────────────────────────────────────────────────────────────────────

variable "apim_publisher_name" {
  type        = string
  description = "Publisher name shown in the APIM developer portal."
}

variable "apim_publisher_email" {
  type        = string
  description = "Publisher e-mail address required by APIM."
}
