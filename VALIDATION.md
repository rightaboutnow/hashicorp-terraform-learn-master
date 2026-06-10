# Setup Validation Guide

Commands to validate that the Terraform + GitHub Actions + Azure OIDC setup is wired
correctly. Run from the repo root. Substitute your own IDs where noted; the values below
are the ones for this project (subscription **terraform-test**, repo
**rightaboutnow/terraform-learn**).

Reference IDs used throughout:

```bash
APP_ID="65045553-6389-4fbb-8c99-4402e1dc11d3"          # AZURE_CLIENT_ID (github-actions-terraform)
SP_OBJECT_ID="7226a2f3-848b-4d90-8e44-e1094e995356"    # service principal object id
SUBSCRIPTION_ID="ca91a545-28b9-4e3c-af0b-5acfc817a6ad" # terraform-test
TENANT_ID="6f58b108-5b0f-4872-a348-4882ef8ba516"
STATE_RG="tfstate-rg"
STATE_SA="tfstate439921213"
STATE_CONTAINER="tfstate"
GITHUB_REPO="rightaboutnow/terraform-learn"
```

---

## 1. Local Terraform Validation

No Azure auth needed — `-backend=false` skips the remote state backend.

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

**Expected:** `id` = `ca91a545-…`, `tenantId` = `6f58b108-…`, name `terraform-test`.

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
| `github-main`     | `repo:rightaboutnow/terraform-learn:ref:refs/heads/main`       |
| `github-env-dev`  | `repo:rightaboutnow/terraform-learn:environment:dev`           |
| `github-env-test` | `repo:rightaboutnow/terraform-learn:environment:test`          |
| `github-env-prod` | `repo:rightaboutnow/terraform-learn:environment:prod`          |

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

There is also an older `Storage Blob Data Contributor` scoped to just the **state** storage
account (a child scope — won't show in the subscription list above). It's now redundant with the
subscription-scoped grant but harmless:

```bash
SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$STATE_RG/providers/Microsoft.Storage/storageAccounts/$STATE_SA"
az role assignment list --assignee "$SP_OBJECT_ID" --scope "$SCOPE" --include-inherited -o table
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
(`learnapp-<env>.tfstate`), so each env has its own blob:

```bash
# List per-environment state blobs (created on first apply of each env)
az storage blob list --container-name "$STATE_CONTAINER" --account-name "$STATE_SA" \
  --auth-mode login --query "[].name" -o tsv
# Expect: learnapp-dev.tfstate, learnapp-test.tfstate, learnapp-prod.tfstate (as you deploy each)
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

**Expected:** SSH greets you as `rightaboutnow`. `git ls-remote` exits 0; a non-empty
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

**Expected:** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` set to the IDs
in the reference block above (Settings → Secrets and variables → Actions → Variables).

---

## Validation Results (2026-06-08)

| Area | Check | Status |
|------|-------|--------|
| Local | `terraform fmt -check` | ✅ clean |
| Local | `terraform validate` | ✅ valid |
| Local | provider version locked | ✅ azurerm 4.76.0 |
| Azure | subscription / tenant | ✅ terraform-test, tenant matches |
| Azure | app registration | ✅ github-actions-terraform |
| Azure | service principal | ✅ exists |
| Azure | federated credential `github-main` | ✅ matches dispatch on main (plan job) |
| Azure | federated credentials `github-env-dev/test/prod` | ✅ match apply/destroy per environment |
| Azure | RBAC Contributor (subscription) | ✅ |
| Azure | RBAC User Access Administrator (subscription) | ✅ |
| Azure | RBAC Storage Blob Data Contributor (subscription — for created storage accounts) | ✅ |
| Azure | storage account hardening | ✅ TLS1.2, public off, shared-key off |
| Azure | state container (Azure AD auth) | ✅ reachable |
| GitHub | SSH access | ✅ as rightaboutnow |
| GitHub | repo `rightaboutnow/terraform-learn` | ✅ exists |
| GitHub | code pushed to repo | ⚠️ empty — nothing pushed yet |
| GitHub | local dir is a git repo | ❌ not initialized |
| GitHub | Actions variables | ⏳ not verified (needs gh CLI / PAT) |
</content>
