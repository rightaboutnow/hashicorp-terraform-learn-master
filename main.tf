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
