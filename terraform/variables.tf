variable "name_prefix" {
  description = "Lowercase alphanumeric prefix used for Azure resource names."
  type        = string
  default     = "aksdemo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,9}$", var.name_prefix))
    error_message = "name_prefix must be 3-10 lowercase alphanumeric characters and start with a letter."
  }
}

variable "location" {
  description = "Azure region for the environment."
  type        = string
  default     = "eastus"
}

variable "acr_replica_location" {
  description = "Secondary region for zone-redundant ACR replication."
  type        = string
  default     = "eastus2"

  validation {
    condition     = lower(replace(var.acr_replica_location, " ", "")) != lower(replace(var.location, " ", ""))
    error_message = "acr_replica_location must differ from location."
  }
}

variable "aks_admin_object_ids" {
  description = "Entra object IDs allowed to administer Kubernetes through Azure RBAC."
  type        = list(string)
  default     = []
}

variable "ci_principal_object_id" {
  description = "Optional Entra service principal object ID used by GitHub Actions for cluster administration and ACR pushes."
  type        = string
  default     = null
  nullable    = true
}

variable "tags" {
  description = "Tags applied to Azure resources."
  type        = map(string)
  default = {
    project     = "aks-production-platform"
    environment = "demo"
    managed_by  = "terraform"
  }
}
