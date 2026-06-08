# main.tf
# Define your Azure resources here as you learn.
#
# Example to get started (uncomment and adjust):
#
# resource "azurerm_resource_group" "main" {
#   name     = var.resource_group_name
#   location = var.location
#   tags     = var.tags
# }


resource "azurerm_resource_group" "main" {
  name     = "rg-${var.application_name}-${var.environment_name}"
  location = var.location
  tags     = var.tags
}

resource "random_string" "storage_account_suffix" {
  length  = 8
  upper   = false
  numeric = true
  special = false
}

locals {
  # Storage account names must be 3-24 chars, lowercase letters + digits only.
  # Keep the 8-char random suffix intact for global uniqueness, and truncate the
  # descriptive prefix to 16 chars so prefix + suffix never exceeds 24.
  storage_account_prefix = substr(
    lower(replace("sa${var.application_name}${var.environment_name}", "/[^a-z0-9]/", "")),
    0, 16
  )
}

resource "azurerm_storage_account" "example" {
  name                     = "${local.storage_account_prefix}${random_string.storage_account_suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = var.tags
}
