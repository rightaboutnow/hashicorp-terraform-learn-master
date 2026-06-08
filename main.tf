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
  length  = 15
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "example" {
  name                     = "sa${var.application_name}${var.environment_name}${random_string.storage_account_suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = var.tags
}
