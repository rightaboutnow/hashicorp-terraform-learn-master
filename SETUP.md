# Setup — GitHub Actions + Azure Terraform with OIDC

How to provision this setup and how it works. Provisioning is automated by
[scripts/bootstrap.sh](scripts/bootstrap.sh); this doc covers running it and explains what it
builds and why. To verify a provisioned setup, see [VALIDATION.md](VALIDATION.md).

```
GitHub Actions → OIDC JWT token → Azure AD validates → short-lived access token → Azure APIs
```

No client secrets or storage keys are stored anywhere.

## Two layers

| Layer | Creates | Auth | Run |
|---|---|---|---|
| **Bootstrap** (this doc) | Azure AD app, federated creds, RBAC, state storage, GitHub variables + environments | A human's privileged `az`/`gh` login | **Once** per (repo, subscription) |
| **Deploy** (the workflows) | Your actual infra, per environment | OIDC, no secrets | Every change |

The bootstrap can't run in the pipeline — it *creates* the OIDC trust the pipeline
authenticates with. It's idempotent, so re-running is safe.

---

## Quick start

### 1. Prerequisites

The bootstrap needs privileged "first credentials" (it creates app registrations and assigns
roles — unavoidable):

- **Azure CLI** logged in as a user who can create Entra app registrations and assign roles
  (Application Administrator + Owner / User Access Administrator): `az login`
- **GitHub CLI** authenticated with repo-admin rights: `gh auth login`
- **The GitHub repo already exists** (create it manually first).

### 2. Configure

Put the two required values in [scripts/bootstrap.env](scripts/bootstrap.env) (auto-sourced):

```bash
export GITHUB_OWNER="<org>"     # org/user that owns the repo
export GITHUB_REPO="<repo>"    # repo name (must already exist)
```

Everything else has a default — override any of these inline or in `bootstrap.env`:

| Variable | Default | Notes |
|---|---|---|
| `GITHUB_OWNER` / `GITHUB_REPO` | — | **required** |
| `PROD_REVIEWERS` | *(empty)* | GitHub usernames for the prod approval gate. **Empty → prod has no reviewer → apply runs unattended.** |
| `APP_NAME` | `github-actions-terraform` | Entra app display name |
| `SUBSCRIPTION_ID` / `TENANT_ID` | current `az` account | |
| `LOCATION` | `australiaeast` | |
| `ENVIRONMENTS` | `dev test prod` | space-separated |
| `REVIEWED_ENVS` | `prod` | which envs require an approver |
| `STATE_RG` / `STATE_CONTAINER` | `tfstate-rg` / `tfstate` | |
| `STATE_SA` | derived from subscription id | set explicitly to **reuse** an existing account (e.g. `<state-storage-account>`) |

### 3. Run

```bash
az login && gh auth login
./scripts/bootstrap.sh                  # reads scripts/bootstrap.env
# or override inline:
PROD_REVIEWERS=<org> ./scripts/bootstrap.sh
```

### 4. After bootstrap

1. Ensure the backend in [versions.tf](versions.tf) points at the state account the script
   created/reused (`storage_account_name`, `resource_group_name`, `container_name`). The values
   are also written as the `TFSTATE_*` GitHub variables.
2. Push the code to `main`.
3. Run the **Terraform Apply** workflow and pick an environment.
4. Confirm everything with [VALIDATION.md](VALIDATION.md).

---

## What it creates, and why

| Component | Why it exists |
|---|---|
| **Azure AD app + service principal** | The identity the pipeline acts as. No secret — it's assumed via OIDC. |
| **Federated credentials** | The trust rules. `github-main` (subject `…:ref:refs/heads/main`) for the plan jobs; `github-env-<env>` (`…:environment:<env>`) for apply/destroy, because setting `environment: <env>` on a job changes the OIDC token's subject. |
| **RBAC** (subscription scope) | `Contributor` (manage resources), `User Access Administrator` (Terraform-managed role assignments), `Storage Blob Data Contributor` (blob **data**-plane access — see below). |
| **Remote state storage** | An Azure Blob container holding Terraform state, hardened (TLS1.2, no public blob, shared-key disabled → Azure AD auth only). |
| **GitHub Actions variables** | `AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID` + `TFSTATE_*` — non-secret identifiers the workflows read. |
| **GitHub Environments** (`dev`/`test`/`prod`) | The approval gate (required reviewer) and the source of the `environment:<env>` OIDC subject. |

> Subscription-scoped RBAC is intentional: the `rg-<app>-<env>` resource groups are created **by
> the pipeline**, so a role scoped to them couldn't exist beforehand. Subscription scope covers
> current and future environments with nothing to pre-provision.

### Why `Storage Blob Data Contributor` + `storage_use_azuread`

Storage accounts set `shared_access_key_enabled = false`. After creating one, the azurerm
provider polls the blob **data plane** and by default authenticates with the account key — now
forbidden, giving `403 Key based authentication is not permitted`. So the provider sets
`storage_use_azuread = true` (use Azure AD for data-plane ops), and the SP needs a blob **data**
role. Management-plane `Contributor` does **not** grant blob data access — hence the separate
`Storage Blob Data Contributor`.

---

## Remote state: the partial backend

The `backend "azurerm"` block in [versions.tf](versions.tf) is **fully partial** — the account,
RG, container, and the per-environment `key` are all supplied at init via `-backend-config`, so
the file is repo/subscription-agnostic. In CI these come from the repo's **GitHub Actions
variables** (`TFSTATE_RESOURCE_GROUP` / `TFSTATE_STORAGE_ACCOUNT` / `TFSTATE_CONTAINER`, set by
the bootstrap); the key is `<app>-<env>.tfstate`:

```hcl
backend "azurerm" {
  use_oidc         = true
  use_azuread_auth = true   # Azure AD (not access keys) for the blob
  # account / resource_group / container / key all via -backend-config at init
}
```

The pipeline's init step therefore looks like:

```bash
terraform init \
  -backend-config="resource_group_name=${{ vars.TFSTATE_RESOURCE_GROUP }}" \
  -backend-config="storage_account_name=${{ vars.TFSTATE_STORAGE_ACCOUNT }}" \
  -backend-config="container_name=${{ vars.TFSTATE_CONTAINER }}" \
  -backend-config="key=<app>-<env>.tfstate"
```

The provider config:

```hcl
provider "azurerm" {
  features {}
  use_oidc            = true
  storage_use_azuread = true
}
```

---

## The deploy workflows (pick env → plan → apply)

The pipeline is [.github/workflows/terraform-apply.yml](.github/workflows/terraform-apply.yml) —
`workflow_dispatch` only, and it **asks which environment** (`dev`/`test`/`prod`). Two jobs:

1. **Plan** — Azure OIDC login → `terraform init -backend-config="key=<app>-<env>.tfstate"`,
   `fmt -check`, `validate`, then `plan -var-file=environments/<env>.tfvars -out=tfplan`, and
   uploads the plan. No `environment:` here, so it auths with `github-main`.
2. **Apply** — `needs: plan`, sets `environment: <env>` (pauses for the required reviewer if the
   environment has one, and switches the OIDC subject to `…:environment:<env>`), re-inits with
   the same key, downloads the plan artifact, and runs `terraform apply tfplan`.

Companion workflows follow the same env-choice pattern:
[terraform-destroy.yml](.github/workflows/terraform-destroy.yml) (pick env + type `destroy`,
reviewable plan-destroy → approve) and
[unlock-state.yml](.github/workflows/unlock-state.yml) (pick env to break that state's lock).

---

## How the token flow works

```
1. Runner requests an OIDC JWT from GitHub (claims: repo, ref/environment, …)
2. azure/login sends the JWT to Azure AD
3. Azure AD checks it against the federated credential rules:
     issuer  = token.actions.githubusercontent.com
     subject = repo:<org>/<repo>:ref:refs/heads/main   (or :environment:<env>)
4. Azure AD returns a short-lived (~1h) access token
5. Terraform fetches its own token the same way via ARM_USE_OIDC=true
```

---

## Security properties

- **No secrets stored** — client/tenant/subscription IDs are non-sensitive identifiers.
- **Short-lived tokens** — ~1-hour access tokens, auto-refreshed.
- **Scoped trust** — each federated credential is locked to a specific repo + ref/environment.
- **No storage keys** — shared-key access disabled; all blob access is Azure AD.
- **Auditable** — every access is logged in Azure AD sign-in logs under the service principal.

## Notes

- **Required reviewers** on environment protection rules need a **public** repo or **GitHub
  Pro/Team/Enterprise** on a private repo. Without it the environment exists but apply won't pause.
- Re-running the bootstrap is safe — existing resources are reported as skipped, and an existing
  environment's protection isn't clobbered.
- Federated credentials cap at ~20 per app; many repos sharing one app would eventually need a
  split. Not a concern for one or two.
