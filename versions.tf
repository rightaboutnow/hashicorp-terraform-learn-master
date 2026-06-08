terraform {
  required_version = ">= 1.15.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.76"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
  }

  # Remote state in Azure Blob Storage.
  # Values are bootstrapped once via the az CLI (see the setup doc).
  # Auth uses OIDC — no access keys or secrets stored.
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstate439921213"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
    use_oidc             = true
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
}
