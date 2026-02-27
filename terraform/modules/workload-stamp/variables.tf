variable "workload_name" {
  type        = string
  default     = "wkld"
  description = "Workload identifier used in resource naming (e.g. 'wkld')."
}

variable "stamp_number" {
  type        = number
  description = "Stamp instance number (e.g. 1). Combined with workload_name and environment to produce names like 'func-wkld-1-dev'."
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. 'dev', 'prod'). Used in resource naming."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group in which all stamp resources are created."
}

variable "location" {
  type        = string
  description = "Azure region for all stamp resources."
}

variable "asp_sku" {
  type        = string
  default     = "P1v3"
  description = "App Service Plan SKU. P1v3 is the minimum tier supporting VNet integration with Linux containers."
}

variable "function_apps" {
  type = map(object({
    registry_url = string
    image_name   = string
    image_tag    = optional(string, "latest")
    app_settings = optional(map(string), {})
  }))
  description = <<-EOT
    Map of Function App definitions.  The map key is used as the Function App
    resource name (e.g. "func-wkld-1-dev").  Each value supplies the ACR image
    coordinates and any additional app_settings to merge with the defaults.
  EOT
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for App Service Plan VNet integration.  Must be delegated to Microsoft.Web/serverFarms."
}

variable "private_endpoint_subnet_id" {
  type        = string
  description = "Subnet ID in which Private Endpoints for this stamp are created (storage, Function App, Key Vault)."
}

variable "acr_id" {
  type        = string
  description = "ACR resource ID.  Used for the AcrPull role assignment on each Function App's managed identity."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Log Analytics Workspace resource ID.  All diagnostic settings in this module stream to this workspace."
}

variable "apim_principal_id" {
  type        = string
  description = "Object ID of the APIM system-assigned managed identity.  Granted Key Vault Certificate User and Secrets User so APIM can retrieve mTLS certs in Phase 3."
}

variable "private_dns_zone_ids" {
  type = object({
    blob_storage_zone_id  = string
    file_storage_zone_id  = string
    table_storage_zone_id = string
    queue_storage_zone_id = string
    websites_zone_id      = string
    key_vault_zone_id     = string
  })
  description = "Named Private DNS Zone IDs for the Private Endpoints created by this module."
}

variable "entra_app_client_id" {
  type        = string
  description = "Application (client) ID of the Entra ID app registration for this stamp's Function App. Used to configure EasyAuth (auth_settings_v2) so the Function App validates Entra tokens issued by APIM's Managed Identity."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Resource tags applied to all resources in this module."
}
