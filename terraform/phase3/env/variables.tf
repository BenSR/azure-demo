
# ─── Remote state ────────────────────────────────────────────────────────────

variable "state_storage_account_name" {
  type        = string
  description = "Name of the storage account holding Terraform state (in rg-core-deploy). Used to read phase1/core and phase1/env remote state."
}

# ─── Workload stamps ─────────────────────────────────────────────────────────
# Must match the stamps deployed by phase1/env in the same workspace.
# Phase 3 uses stamp_name to construct resource names and to look up outputs
# from the phase1/env remote state (key_vault_ids, function_app_hostnames, etc.).

variable "stamps" {
  type = list(object({
    stamp_name = string
  }))
  description = "List of stamp numbers to configure in Phase 3. stamp_name must be a numeric string (e.g. \"1\", \"2\") matching a stamp deployed by phase1/env."

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

# ─── APIM — API Operations ───────────────────────────────────────────────────
# Defines the HTTP operations exposed on the workload API in APIM.
# Override per environment in the workspace-specific .tfvars file as needed.

variable "api_operations" {
  type = list(object({
    operation_id = string
    display_name = string
    http_method  = string
    url_template = string
  }))
  description = "List of APIM API operations to expose on the workload API."

  default = [
    {
      operation_id = "health-check"
      display_name = "Health Check"
      http_method  = "GET"
      url_template = "/health"
    },
    {
      operation_id = "post-echo"
      display_name = "Echo"
      http_method  = "POST"
      url_template = "/echo"
    },
  ]
}

# ─── Alerting ─────────────────────────────────────────────────────────────────

variable "alert_email_receivers" {
  type        = list(string)
  default     = []
  description = "List of e-mail addresses to notify when an alert fires. Can be empty to create a silent action group."
}

variable "alert_5xx_failure_threshold" {
  type        = number
  default     = 5
  description = "Number of failed Function App requests (requests/failed count) in the evaluation window before the alert triggers."

  validation {
    condition     = var.alert_5xx_failure_threshold >= 1
    error_message = "Failure threshold must be at least 1."
  }
}

variable "alert_5xx_window_minutes" {
  type        = number
  default     = 15
  description = "Evaluation window in minutes for the request failure alert. Must be a multiple of 5."

  validation {
    condition     = contains([5, 10, 15, 30, 45, 60], var.alert_5xx_window_minutes)
    error_message = "Window must be one of: 5, 10, 15, 30, 45, 60 minutes."
  }
}

variable "alert_availability_threshold_percent" {
  type        = number
  default     = 99.0
  description = "Minimum availability percentage (0–100) before the availability alert triggers."

  validation {
    condition     = var.alert_availability_threshold_percent > 0 && var.alert_availability_threshold_percent <= 100
    error_message = "Availability threshold must be between 0 and 100 (exclusive lower, inclusive upper)."
  }
}
