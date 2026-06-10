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
  #
  # PARTIAL backend: `key` is intentionally omitted so each environment gets its
  # own state file. The pipeline supplies it at init time, e.g.:
  #   terraform init -backend-config="key=learnapp-dev.tfstate"
  # Locally:
  #   terraform init -backend-config="key=learnapp-<env>.tfstate"
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstate439921213"
    container_name       = "tfstate"
    use_oidc             = true
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
}
