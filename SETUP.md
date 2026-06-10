# GitHub Actions + Azure Terraform with OIDC (Workload Identity Federation)

## Architecture Overview

```
GitHub Actions → OIDC JWT token → Azure AD validates → short-lived access token → Azure APIs
```

No client secrets or certificates stored in GitHub.

---

## Step 1: Create an Azure AD App Registration

```bash
# Create the app registration
az ad app create --display-name "github-actions-terraform"

# Note the appId (client ID) from output
APP_ID=$(az ad app list --display-name "github-actions-terraform" --query "[0].appId" -o tsv)

# Create a service principal for it
az ad sp create --id $APP_ID
SP_OBJECT_ID=$(az ad sp show --id $APP_ID --query id -o tsv)
```

---

## Step 2: Configure Federated Identity Credentials

This tells Azure to trust OIDC tokens from your specific GitHub repo:

```bash
# Replace with your actual GitHub org/repo
GITHUB_ORG="rightaboutnow"
GITHUB_REPO="terraform-learn"

# For the main branch
az ad app federated-credential create \
  --id $APP_ID \
  --parameters '{
    "name": "github-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:'"$GITHUB_ORG/$GITHUB_REPO"':ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# One credential per environment. The apply/destroy jobs set
# `environment: <env>`, which changes the OIDC subject to
# repo:<org>/<repo>:environment:<env> — so each env needs its own credential.
for ENV in dev test prod; do
  az ad app federated-credential create --id $APP_ID --parameters "{
    \"name\": \"github-env-$ENV\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$GITHUB_ORG/$GITHUB_REPO:environment:$ENV\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
done
```

> **Quoting note:** build the `subject` so `$GITHUB_ORG/$GITHUB_REPO` actually expands —
> if the full `repo:.../.../environment:<env>` doesn't appear in the created credential,
> the subject got mangled. Verify with:
> `az ad app federated-credential list --id $APP_ID --query "[].{name:name, subject:subject}" -o table`

---

## Step 3: Assign Azure RBAC Roles

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Contributor on the subscription (or scope to a resource group for least privilege)
az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

# If Terraform manages role assignments, also add:
az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role "User Access Administrator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

# Data-plane blob access for the storage accounts Terraform CREATES.
# These set shared_access_key_enabled = false, so the provider must reach the
# blob data plane via Azure AD (provider sets storage_use_azuread = true). Without
# this role the post-create data-plane poll fails with:
#   403 "Key based authentication is not permitted on this storage account."
# Contributor (above) is management-plane only and does NOT grant blob data access.
az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

> Scope shown at the subscription so it covers every `rg-<app>-<env>` Terraform creates. For
> tighter least-privilege you can instead assign it per resource group once the RGs exist.

---

## Step 4: Bootstrap Remote State Storage (Blob)

Terraform needs a place to store its state file. We create an Azure Storage Account + Blob container **once**, manually, using the az CLI. The pipeline then uses this for remote state. Auth to the blob uses OIDC (Azure AD), so **no storage access keys are stored anywhere**.

```bash
# Use globally-unique names. Storage account names: 3-24 chars, lowercase letters + numbers only.
STATE_RG="tfstate-rg"
STATE_SA="tfstate$RANDOM$RANDOM"   # must be globally unique
STATE_CONTAINER="tfstate"
LOCATION="australiaeast"

# 1. Resource group to hold the state storage
az group create --name $STATE_RG --location $LOCATION

# 2. Storage account (TLS 1.2, no public blob access, key access disabled → forces Azure AD auth)
az storage account create \
  --name $STATE_SA \
  --resource-group $STATE_RG \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false

# 3. Blob container for the state file
az storage container create \
  --name $STATE_CONTAINER \
  --account-name $STATE_SA \
  --auth-mode login

echo "Storage account name: $STATE_SA"   # put this into versions.tf backend block
```

Because we disabled shared key access, the service principal needs a data-plane role to read/write the state blob:

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az role assignment create \
  --assignee $SP_OBJECT_ID \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$STATE_RG/providers/Microsoft.Storage/storageAccounts/$STATE_SA"
```

Then put the storage account name into the backend block in `versions.tf`. Note the
**partial backend** — `key` is omitted so each environment gets its own state file; the
pipeline supplies it at init time:

```hcl
backend "azurerm" {
  resource_group_name  = "tfstate-rg"
  storage_account_name = "tfstate439921213"   # <-- the $STATE_SA value from above
  container_name       = "tfstate"
  # key intentionally omitted (partial backend) — set per environment at init:
  #   terraform init -backend-config="key=learnapp-dev.tfstate"
  use_oidc             = true
  use_azuread_auth     = true                # use Azure AD (not access keys) for the blob
}
```

---

## Step 5: Add GitHub Repository Variables

In your GitHub repo → **Settings → Secrets and Variables → Actions → Variables** (not secrets — these aren't sensitive):

| Name | Value |
|------|-------|
| `AZURE_CLIENT_ID` | `65045553-6389-4fbb-8c99-4402e1dc11d3` (github-actions-terraform app) |
| `AZURE_TENANT_ID` | `6f58b108-5b0f-4872-a348-4882ef8ba516` (Default Directory tenant) |
| `AZURE_SUBSCRIPTION_ID` | `ca91a545-28b9-4e3c-af0b-5acfc817a6ad` (terraform-test subscription) |

> All three IDs are filled in for **terraform-test** (`ca91a545…`) in your Default Directory tenant. Just copy them into GitHub → Settings → Secrets and Variables → Actions → Variables.

---

## Step 6: Terraform Project Files

The Terraform configuration lives in the repo root, plus per-environment tfvars:

- `versions.tf` — Terraform/provider versions and the **partial** remote state backend
- `main.tf` — resources + naming/tags locals
- `variables.tf` — input variables (naming, governance, storage, networking)
- `outputs.tf` — outputs
- `environments/{dev,test,prod}.tfvars` — per-environment values (committed; no secrets)

The backend in `versions.tf` is a **partial backend** — `key` is omitted so each environment
gets its own state file (`learnapp-<env>.tfstate`), supplied at init time:

```hcl
# versions.tf
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

  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstate439921213" # from Step 4
    container_name       = "tfstate"
    use_oidc             = true
    use_azuread_auth     = true
    # key supplied at init: terraform init -backend-config="key=learnapp-<env>.tfstate"
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
}
```

---

## Step 7: GitHub Actions Workflow (pick env → plan → apply)

The pipeline lives in [.github/workflows/terraform-apply.yml](.github/workflows/terraform-apply.yml) — that
file is the single source of truth; this section summarizes it. It's **`workflow_dispatch`
only** and **asks which environment** (`dev`/`test`/`prod`) to target. Two jobs:

1. **Plan** — checkout → Azure OIDC login → `terraform init -backend-config="key=learnapp-<env>.tfstate"`,
   `fmt -check`, `validate`, then `terraform plan -var-file=environments/<env>.tfvars -out=tfplan`,
   and uploads the plan artifact. No `environment:` on this job, so it auths with `github-main`.
2. **Apply** — `needs: plan`, targets the **`<env>`** GitHub Environment, re-inits with the same
   `-backend-config`, downloads the plan artifact, and runs `terraform apply tfplan`.

> **Per-environment approval gate:** the apply job sets `environment: <env>`. If that GitHub
> Environment has a required reviewer (recommended at least for `prod`), the run **pauses** at
> apply for an **Approve / Reject** click. Setting `environment: <env>` also changes the OIDC
> subject to `repo:<org>/<repo>:environment:<env>`, matched by the `github-env-<env>` credential
> from Step 2. Create the `dev`/`test`/`prod` environments (and reviewers) per
> [README.md](README.md#create-the-github-environments).

> **Why apply re-runs `terraform init`:** it runs on a fresh runner, so the `.terraform`
> provider cache and backend config don't carry over from the plan job. Re-init uses the same
> `-backend-config` key, and the `tfplan` artifact is passed plan → apply so apply executes
> exactly the plan you reviewed.

The companion workflows follow the same env-choice pattern:
[terraform-destroy.yml](.github/workflows/terraform-destroy.yml) (pick env + type `destroy`) and
[unlock-state.yml](.github/workflows/unlock-state.yml) (pick env to break that state's lock).

---

## How the Token Flow Works

```
1. GitHub Actions runner starts
2. Runner requests OIDC JWT from GitHub's token endpoint
   └─ JWT contains: repo, branch, workflow, etc.
3. azure/login action sends JWT to Azure AD
4. Azure AD validates JWT against your federated credential rules
   └─ Checks issuer = token.actions.githubusercontent.com
   └─ Checks subject = repo:org/repo:ref:refs/heads/main
5. Azure AD returns a short-lived access token (1 hour)
6. Terraform uses ARM_USE_OIDC=true to fetch tokens the same way
```

---

## Key Security Properties

- **No secrets stored** — client ID, tenant ID, and subscription ID are non-sensitive identifiers
- **Short-lived tokens** — 1-hour access tokens, auto-refreshed
- **Scoped trust** — federated credential is locked to your specific repo + branch
- **Auditable** — all access logged in Azure AD sign-in logs under the service principal

The `subject` claim in the federated credential is what scopes the trust. This project uses `ref:refs/heads/main` (the plan jobs) and `environment:<env>` for `dev`/`test`/`prod` (the apply/destroy jobs); other forms like `pull_request` are available if you add those triggers.
