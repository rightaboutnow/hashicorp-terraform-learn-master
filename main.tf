# main.tf
# Resources for the <application_name> workload, deployed per environment (dev/test/prod).
# Per-environment values come from environments/<env>.tfvars.

locals {
  # Short region code for naming (falls back to "xx" for unmapped regions).
  location_short = lookup(var.location_abbreviations, var.location, "xx")

  # Resource group name: explicit override, else computed.
  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "rg-${var.application_name}-${var.environment_name}"

  # Tags applied to every resource. Computed here (a variable default can't
  # reference other variables), then merged with any caller-supplied extras.
  common_tags = merge(
    {
      application = var.application_name
      environment = var.environment_name
      managed_by  = "terraform"
      owner       = var.owner
      owner_email = var.owner_email
      cost_center = var.cost_center
    },
    var.additional_tags,
  )

  # Storage account names must be 3-24 chars, lowercase letters + digits only.
  # Truncate the descriptive prefix to 12 chars so prefix + 12-char random
  # suffix never exceeds 24.
  storage_account_prefix = substr(
    lower(replace("sa${var.application_name}${var.environment_name}", "/[^a-z0-9]/", "")),
    0, 12
  )
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags
}

resource "random_string" "storage_account_suffix" {
  length  = 12
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "example" {
  name                = "${local.storage_account_prefix}${random_string.storage_account_suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  account_tier             = var.storage_account_tier
  account_replication_type = var.storage_account_replication_type
  account_kind             = var.storage_account_kind

  min_tls_version                 = var.storage_min_tls_version
  allow_nested_items_to_be_public = var.storage_allow_public_blob_access
  shared_access_key_enabled       = var.storage_shared_access_key_enabled

  tags = local.common_tags
}
