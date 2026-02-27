variable "resource_group_name" {
  type        = string
  description = "Name of the resource group in which to create the Private DNS Zones."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Resource tags to apply to all Private DNS Zones."
}
