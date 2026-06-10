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

  # Remote state in Azure Blob Storage, authenticated with OIDC + Azure AD — no
  # access keys or secrets stored.
  #
  # PARTIAL backend: the account/RG/container and the per-environment state key
  # are all supplied at init via -backend-config, so this file stays
  # repo/subscription-agnostic. In CI they come from the repo's GitHub Actions
  # variables (TFSTATE_RESOURCE_GROUP / TFSTATE_STORAGE_ACCOUNT / TFSTATE_CONTAINER)
  # set by scripts/bootstrap.sh; the key is <app>-<env>.tfstate. Example:
  #   terraform init \
  #     -backend-config="resource_group_name=tfstate-rg" \
  #     -backend-config="storage_account_name=tfstate439921213" \
  #     -backend-config="container_name=tfstate" \
  #     -backend-config="key=learnapp-dev.tfstate"
  backend "azurerm" {
    use_oidc         = true
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}
  use_oidc = true

  # Storage accounts here have shared-key access disabled, so the provider must
  # use Azure AD (the OIDC identity) for blob/queue/table data-plane operations
  # instead of account keys. Requires the principal to hold a "Storage Blob Data*"
  # role on the accounts it manages.
  storage_use_azuread = true
}
