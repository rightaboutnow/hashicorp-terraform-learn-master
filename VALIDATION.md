# Setup Validation Guide

Commands to validate that the Terraform + GitHub Actions + Azure OIDC setup is wired
correctly — e.g. after running [scripts/bootstrap.sh](scripts/bootstrap.sh) (see
[SETUP.md](SETUP.md)). Run from the repo root. Substitute your own IDs where noted;
the values below are the ones for this project (subscription **<subscription-name>**, repo
**<org>/<repo>**).

Run the sections in order. **Section 1** needs no Azure auth; **2–6** need `az login`;
**7** needs `gh` (or a PAT).

Reference IDs used throughout:

```bash
APP_ID="<client-id>"          # AZURE_CLIENT_ID (github-actions-terraform)
SP_OBJECT_ID="<sp-object-id>"    # service principal object id
SUBSCRIPTION_ID="<subscription-id>" # <subscription-name>
TENANT_ID="<tenant-id>"
STATE_RG="tfstate-rg"
STATE_SA="<state-storage-account>"
STATE_CONTAINER="tfstate"
GITHUB_REPO="<org>/<repo>"
```

---

## 1. Local Terraform Validation

No Azure auth needed — `-backend=false` skips the remote state backend. Quick one-liner:

```bash
terraform fmt -check -recursive && \
  terraform init -backend=false -input=false >/dev/null && \
  terraform validate && rm -rf .terraform
```

Or step by step:

```bash
# Tooling versions
terraform version
az version

# Formatting (exit 0 = clean)
terraform fmt -check -recursive

# Initialize providers only (no backend), then validate the config
terraform init -backend=false -input=false
terraform validate

# Confirm the provider version that got locked
grep -E 'version|constraints' .terraform.lock.hcl

# Clean up the local provider cache when done (keep .terraform.lock.hcl)
rm -rf .terraform
```

**Expected:** `fmt` exits 0, `validate` prints `Success! The configuration is valid.`,
and the lock file pins `azurerm` `4.76.0` (constraint `~> 4.76`).

---

## 2. Azure Authentication

```bash
# Confirm the right subscription + tenant
az account show -o json
```

**Expected:** `id` = `<subscription-id>`, `tenantId` = `<tenant-id>`, name `<subscription-name>`.

---

## 3. App Registration & Service Principal

```bash
# App registration exists
az ad app show --id "$APP_ID" \
  --query "{displayName:displayName, appId:appId}" -o json

# Service principal exists (note its object id)
az ad sp show --id "$APP_ID" \
  --query "{displayName:displayName, id:id, appId:appId}" -o json
```

**Expected:** both return `displayName = github-actions-terraform`; the SP `id` is the
`$SP_OBJECT_ID` above.

---

## 4. Federated Identity Credentials (OIDC)

```bash
az ad app federated-credential list --id "$APP_ID" \
  --query "[].{name:name, subject:subject, issuer:issuer, audiences:audiences}" -o json
```

**Expected:** four credentials, issuer `https://token.actions.githubusercontent.com`,
audience `api://AzureADTokenExchange`:

| name              | subject                                                        |
|-------------------|----------------------------------------------------------------|
| `github-main`     | `repo:<org>/<repo>:ref:refs/heads/main`       |
| `github-env-dev`  | `repo:<org>/<repo>:environment:dev`           |
| `github-env-test` | `repo:<org>/<repo>:environment:test`          |
| `github-env-prod` | `repo:<org>/<repo>:environment:prod`          |

> `github-main` covers the **plan** job (`workflow_dispatch` on main → subject is the main ref).
> The **apply/destroy** jobs set `environment: <env>`, which changes the subject to
> `…:environment:<env>` — matched by the `github-env-<env>` credentials. Without these, apply's
> Azure login fails.

---

## 5. RBAC Role Assignments

Management-plane roles live at subscription scope:

```bash
az role assignment list --assignee "$SP_OBJECT_ID" --include-inherited -o table
```

**Expected:** three roles at `/subscriptions/$SUBSCRIPTION_ID`:
- `Contributor` — management plane
- `User Access Administrator` — for Terraform-managed role assignments
- `Storage Blob Data Contributor` — data-plane blob access for the storage accounts Terraform
  creates (they disable shared-key auth, and the provider uses `storage_use_azuread = true`).
  Without it, apply fails with `403 Key based authentication is not permitted`.

All three are at subscription scope, so they inherit down to every resource group the pipeline
creates (`rg-<app>-<env>`) and to the state storage account — no per-account assignment needed.
Confirm the state account is covered via inheritance:

```bash
SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$STATE_RG/providers/Microsoft.Storage/storageAccounts/$STATE_SA"
az role assignment list --assignee "$SP_OBJECT_ID" --scope "$SCOPE" --include-inherited -o table
# Expect: Contributor, User Access Administrator, Storage Blob Data Contributor (all inherited)
```

> Note: `--all` together with `--assignee` errors on az 2.75 (`group or scope are not
> required when --all is used`). Use `--include-inherited` / `--scope` instead, as above.

---

## 6. Remote State Storage

```bash
# Storage account hardening
az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" \
  --query "{name:name, location:location, sku:sku.name, kind:kind, tls:minimumTlsVersion, publicBlob:allowBlobPublicAccess, sharedKey:allowSharedKeyAccess, provisioning:provisioningState}" -o json

# Container exists and is reachable via Azure AD auth (not access keys)
az storage container show --name "$STATE_CONTAINER" --account-name "$STATE_SA" \
  --auth-mode login --query "{name:name}" -o json
```

**Expected:** `StorageV2`, `Standard_LRS`, `australiaeast`, `minimumTlsVersion = TLS1_2`,
`allowBlobPublicAccess = false`, `allowSharedKeyAccess = false`, `provisioningState =
Succeeded`; container `tfstate` returns its name (proves Azure AD data-plane access works).

The storage account + container must match the `backend "azurerm"` block in
[versions.tf](versions.tf). The backend is **partial** — `key` is set per environment at init
(`<app>-<env>.tfstate`), so each env has its own blob:

```bash
# List per-environment state blobs (created on first apply of each env)
az storage blob list --container-name "$STATE_CONTAINER" --account-name "$STATE_SA" \
  --auth-mode login --query "[].name" -o tsv
# Expect: <app>-dev.tfstate, <app>-test.tfstate, <app>-prod.tfstate (as you deploy each)
```

---

## 7. GitHub Repository

### Over SSH (git transport only)

```bash
# SSH auth identity (should be the OIDC org owner)
ssh -T git@github.com

# Repo exists and what's pushed to it
git ls-remote git@github.com:$GITHUB_REPO.git
```

**Expected:** SSH greets you as `<org>`. `git ls-remote` exits 0; a non-empty
output lists branches. **Empty output = repo exists but nothing has been pushed yet** —
the pipeline can't run until the code is on `main`.

### Actions repository variables (needs the REST API, not SSH)

SSH keys only authorize git transport. Reading Actions variables requires the `gh` CLI or
a PAT with `repo`/`actions` scope:

```bash
# Option A: gh CLI
gh variable list -R $GITHUB_REPO

# Option B: REST API with a token
curl -s -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/$GITHUB_REPO/actions/variables
```

**Expected:** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (and
`TFSTATE_RESOURCE_GROUP` / `TFSTATE_STORAGE_ACCOUNT` / `TFSTATE_CONTAINER`) set to the values in
the reference block above (Settings → Secrets and variables → Actions → Variables).

### GitHub Environments

```bash
# Each environment exists, and prod has a required reviewer
for env in dev test prod; do
  gh api "repos/$GITHUB_REPO/environments/$env" \
    --jq "{name, reviewers: ([.protection_rules[]? | select(.type==\"required_reviewers\")] | length)}"
done
```

**Expected:** all three environments exist; `prod` reports `reviewers: 1` (or more). An
environment with `reviewers: 0` does **not** pause apply — it runs unattended.
