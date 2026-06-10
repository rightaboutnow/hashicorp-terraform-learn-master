# variables.tf
# Input variables. Per-environment values are supplied via environments/<env>.tfvars
# and the backend state key is set at init time (see versions.tf).

# ──────────────────────────────────────────────────────────────────────────────
# Core identity / naming
# ──────────────────────────────────────────────────────────────────────────────

variable "application_name" {
  description = "Short application/workload name used in resource names and the state key (lowercase letters and digits only)."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[a-z0-9]{2,16}$", var.application_name))
    error_message = "application_name must be 2-16 chars, lowercase letters and digits only."
  }
}

variable "environment_name" {
  description = "Deployment environment. Drives naming, tags, and the state file."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment_name)
    error_message = "environment_name must be one of: dev, test, prod."
  }
}

variable "location" {
  description = "Azure region for resources."
  type        = string
  default     = "australiaeast"
}

variable "location_abbreviations" {
  description = "Map of Azure region -> short code, used in resource names."
  type        = map(string)
  default = {
    australiaeast      = "aue"
    australiasoutheast = "ase"
    eastus             = "eus"
    westeurope         = "weu"
  }
}

variable "resource_group_name" {
  description = "Optional explicit resource group name. Leave empty to compute it as rg-<app>-<env>."
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Ownership / governance (surface as tags)
# ──────────────────────────────────────────────────────────────────────────────

variable "owner" {
  description = "Person or team responsible for these resources."
  type        = string
  default     = "Jenson Thomas"
}

variable "owner_email" {
  description = "Contact email for the owner."
  type        = string
  default     = "jensonzthomas@outlook.com"
}

variable "cost_center" {
  description = "Cost center / billing tag."
  type        = string
  default     = ""
}

variable "additional_tags" {
  description = "Extra tags merged on top of the computed common tags."
  type        = map(string)
  default     = {}
}

# ──────────────────────────────────────────────────────────────────────────────
# Storage account settings (per-environment via tfvars)
# ──────────────────────────────────────────────────────────────────────────────

variable "storage_account_tier" {
  description = "Storage account performance tier."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.storage_account_tier)
    error_message = "storage_account_tier must be Standard or Premium."
  }
}

variable "storage_account_replication_type" {
  description = "Storage replication (LRS for dev/test, GRS/ZRS for prod, etc.)."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "GRS", "RAGRS", "ZRS", "GZRS", "RAGZRS"], var.storage_account_replication_type)
    error_message = "storage_account_replication_type must be one of LRS, GRS, RAGRS, ZRS, GZRS, RAGZRS."
  }
}

variable "storage_account_kind" {
  description = "Storage account kind."
  type        = string
  default     = "StorageV2"
}

variable "storage_min_tls_version" {
  description = "Minimum TLS version for the storage account."
  type        = string
  default     = "TLS1_2"
}

variable "storage_allow_public_blob_access" {
  description = "Whether to allow anonymous public access to blobs."
  type        = bool
  default     = false
}

variable "storage_shared_access_key_enabled" {
  description = "Whether shared (account-key) access is enabled. Prefer Azure AD auth (false)."
  type        = bool
  default     = false
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking placeholders (populate as you grow the project)
# ──────────────────────────────────────────────────────────────────────────────

variable "vnet_address_space" {
  description = "Virtual network address space."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "subnet_prefixes" {
  description = "Map of subnet name -> address prefix."
  type        = map(string)
  default = {
    default = "10.0.1.0/24"
  }
}
