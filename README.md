# terrazlearn — Terraform on Azure with GitHub Actions (OIDC)

A learning project for managing Azure infrastructure with Terraform across **three
environments (dev / test / prod)**, deployed through GitHub Actions using **OpenID Connect
(OIDC)** — no client secrets or storage keys stored anywhere. Each environment has its **own
state file** in an Azure Blob container authenticated with Azure AD.

```
GitHub Actions → OIDC JWT → Azure AD validates → short-lived token (1h) → Azure APIs
```

---

## Repository layout

| File | Purpose |
|------|---------|
| [versions.tf](versions.tf) | Terraform & `azurerm` versions + the **partial** remote state backend |
| [main.tf](main.tf) | Azure resources + naming/tags locals |
| [variables.tf](variables.tf) | Input variables (naming, governance, storage, networking) |
| [outputs.tf](outputs.tf) | Output values (RG, storage account, tags, environment) |
| [environments/dev.tfvars](environments/dev.tfvars) · [test.tfvars](environments/test.tfvars) · [prod.tfvars](environments/prod.tfvars) | Per-environment values (committed; no secrets) |
| [.github/workflows/terraform-apply.yml](.github/workflows/terraform-apply.yml) | Deploy: pick env → plan → approve → apply |
| [.github/workflows/terraform-destroy.yml](.github/workflows/terraform-destroy.yml) | Manual teardown of a chosen environment |
| [.github/workflows/unlock-state.yml](.github/workflows/unlock-state.yml) | Break a stuck state lock for a chosen environment |
| [SETUP.md](SETUP.md) | One-time Azure/GitHub setup guide |
| [VALIDATION.md](VALIDATION.md) | Commands to validate the whole setup |
| [CLAUDE.md](CLAUDE.md) | Architecture & conventions guide for AI agents |

---

## Multi-environment model

| Concern | How it's separated per environment |
|---------|-------------------------------------|
| **State file** | Partial backend; `key` set at init: `learnapp-<env>.tfstate` (one blob per env in the `tfstate` container) |
| **Variables** | `environments/<env>.tfvars` passed via `-var-file` |
| **Approval gate** | A GitHub **Environment** per env (`dev`, `test`, `prod`) with its own reviewer rules |
| **OIDC trust** | A federated credential per env: `repo:<org>/<repo>:environment:<env>` |
| **Concurrency** | Lock group `terraform-<env>` — a dev run never blocks a prod run |

The same `main.tf` deploys all three; only the tfvars and state key change. So
`rg-learnapp-dev`, `rg-learnapp-test`, `rg-learnapp-prod` are fully independent, each with
its own tags, networking, and storage settings from `environments/<env>.tfvars`.

---

## Tooling versions

| Component | Version |
|-----------|---------|
| Terraform | `>= 1.15.0` (CI pins `~1.15`) |
| azurerm provider | `~> 4.76` (locked at 4.76.0) |
| random provider | `3.9.0` |
| actions/checkout | v6 |
| azure/login | v3 |
| hashicorp/setup-terraform | v4 |
| actions/upload-artifact | v7 |
| actions/download-artifact | v8 |

---

## How the deploy pipeline works

[.github/workflows/terraform-apply.yml](.github/workflows/terraform-apply.yml) is
**`workflow_dispatch` only** — it asks which environment to target, then runs two jobs:

1. **Plan** — `terraform init -backend-config="key=learnapp-<env>.tfstate"`, `fmt -check`,
   `validate`, then `terraform plan -var-file=environments/<env>.tfvars`; uploads the plan as
   an artifact. (No environment on this job, so it authenticates with the `github-main`
   credential.)
2. **Apply** — *waits for manual approval.* The job targets the **`<env>`** GitHub Environment.
   If that environment has a required reviewer, the run **pauses after plan** for an
   **Approve / Reject** click, then applies the exact plan from the Plan job.

> Apply runs on a fresh runner, so it re-inits with the same `-backend-config`; the saved plan
> is passed Plan → Apply as an artifact so apply executes exactly what was reviewed.

### Run a deployment

**Actions** → **Terraform Apply** → **Run workflow** → choose **environment** (`dev`/`test`/`prod`)
→ Run. Then review the Plan job and approve the Apply job if the environment gates it.

```bash
# Or via the GitHub CLI
gh workflow run terraform-apply.yml -R rightaboutnow/terraform-learn --ref main -f environment=dev
```

---

## Prerequisites

The Azure/GitHub trust is provisioned once — full steps in
[SETUP.md](SETUP.md). In short:

- An Azure AD **app registration** + **service principal** (`github-actions-terraform`)
- **Federated credentials** trusting these OIDC subjects (all created for this project):
  - `repo:<org>/<repo>:ref:refs/heads/main` — plan jobs / dispatch on main (`github-main`)
  - `repo:<org>/<repo>:environment:dev` — apply/destroy to dev (`github-env-dev`)
  - `repo:<org>/<repo>:environment:test` — apply/destroy to test (`github-env-test`)
  - `repo:<org>/<repo>:environment:prod` — apply/destroy to prod (`github-env-prod`)
- **RBAC**: `Contributor` (+ `User Access Administrator` if Terraform manages role
  assignments) on the subscription, and `Storage Blob Data Contributor` on the state storage
  account
- A **state storage account** (`tfstate439921213`) + `tfstate` container (shared-key access
  disabled → Azure AD only)
- Three **GitHub Actions variables**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_SUBSCRIPTION_ID`
- **GitHub Environments** named `dev`, `test`, `prod`. Add a **required reviewer** to the ones
  you want gated (at minimum `prod`).

### Create the GitHub Environments

**UI:** repo → **Settings** → **Environments** → **New environment** → name it `dev` / `test` /
`prod` → (for gated envs) enable **Required reviewers** → add yourself → **Save**.

**gh CLI** (required reviewer on prod; repeat per env as desired):

```bash
# numeric user id: gh api user --jq .id
gh api -X PUT repos/rightaboutnow/terraform-learn/environments/prod \
  -f "reviewers[][type]=User" -F "reviewers[][id]=USER_ID"

# dev/test with no reviewer (auto-apply after plan) — just create them:
gh api -X PUT repos/rightaboutnow/terraform-learn/environments/dev
gh api -X PUT repos/rightaboutnow/terraform-learn/environments/test
```

The matching Azure federated credentials (`github-env-dev/test/prod`) already exist — verify
with [VALIDATION.md](VALIDATION.md).

---

## Local development

Requires the Terraform CLI and Azure CLI (`az login`).

```bash
# Format and validate without touching the remote backend
terraform fmt -recursive
terraform init -backend=false
terraform validate

# Full init against the real backend for a specific environment (needs az login / OIDC)
terraform init -backend-config="key=learnapp-dev.tfstate"
terraform plan -var-file="environments/dev.tfvars"
```

> `apply` is intentionally left to the CI pipeline. Run it locally only if you know what you
> are doing — and always pass the matching `-backend-config` key and `-var-file`.

---

## First-time deployment checklist

Do these **in order**:

1. **Provision the Azure side** (one-time) — app/SP, the four federated credentials, RBAC,
   state storage. See [SETUP.md](SETUP.md)
   and confirm with [VALIDATION.md](VALIDATION.md).
2. **Set the three GitHub Actions variables** — `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_SUBSCRIPTION_ID` (repo → Settings → Secrets and variables → Actions → Variables).
3. **Create the `dev`, `test`, `prod` GitHub Environments** — add a required reviewer to at
   least `prod`. ⚠️ An environment with no reviewer applies without pausing.
4. **Push the code to `main`** — see [Git commands](#git-commands). Pushing does **not** deploy;
   deploys are manual.
5. **Run Terraform Apply** for `dev` first — Actions → Terraform Apply → Run workflow →
   `environment=dev` → review plan → approve if gated.
6. **Promote** to `test`, then `prod`, the same way.

Quick verification before the first run:

```bash
# Environments exist (and which are gated)
for e in dev test prod; do
  gh api repos/rightaboutnow/terraform-learn/environments/$e --jq '.name, .protection_rules' ; done

# Actions variables are set
gh variable list -R rightaboutnow/terraform-learn

# Per-environment federated credentials exist
az ad app federated-credential list --id "$APP_ID" \
  --query "[?starts_with(subject,'repo:rightaboutnow/terraform-learn:environment:')].{name:name, subject:subject}" -o table
```

---

## Git commands

### First-time setup — initialize and push

Run from the repo root. **Pushing does not deploy** — deploys are manual `workflow_dispatch`.

```bash
git init -b main
git add .                # .gitignore keeps state/plan out; environments/*.tfvars ARE committed
git commit -m "Terraform + GitHub Actions Azure OIDC multi-env pipeline"
git remote add origin git@github.com:rightaboutnow/terraform-learn.git
git push -u origin main
```

### Everyday workflow

```bash
git status
git add -A
git commit -m "Describe the change"
git push                 # pushes to origin/main; run Terraform Apply manually to deploy
```

### Working on a branch (recommended)

```bash
git switch -c feature/add-resource
git add -A && git commit -m "Add resource"
git push -u origin feature/add-resource
# Open a PR, merge to main, then run Terraform Apply for the target env
```

---

## Destroying resources (manual only)

[.github/workflows/terraform-destroy.yml](.github/workflows/terraform-destroy.yml) tears down
**everything in one environment's state**. It's `workflow_dispatch` only and mirrors the deploy
shape — **plan-destroy → approve → destroy**:

1. **Plan Destroy** — pick the **environment** and type `destroy` in the **confirm** box (aborts
   otherwise), then runs `terraform plan -destroy` and uploads the destroy plan listing exactly
   what will be destroyed.
2. **Destroy** — targets the selected **environment**, so it **pauses for reviewer approval** (if
   that env is gated) before applying the destroy plan.

**Double-gated**: the `destroy` confirm word *and* the environment approval.

**Run it:** Actions → **Terraform Destroy** → Run workflow → pick **environment** → set
**confirm** = `destroy` → Run → review the Plan Destroy output → **Approve**.

```bash
gh workflow run terraform-destroy.yml -R rightaboutnow/terraform-learn --ref main \
  -f environment=dev -f confirm=destroy
```

⚠️ Irreversible — deletes all resources that environment's state manages, but **not** the shared
state storage account (bootstrapped outside Terraform).

---

## Troubleshooting

### Run hangs on "Acquiring state lock…"

The `azurerm` backend locks state with a **blob lease** on `learnapp-<env>.tfstate`. A run
cancelled mid-`init`/`plan`/`apply` leaves the lease held, blocking the next run for that
environment.

**Check / break the lease for an environment** (e.g. `dev`):

```bash
az storage blob show --container-name tfstate --name learnapp-dev.tfstate \
  --account-name tfstate439921213 --auth-mode login \
  --query "{leaseStatus:properties.lease.status, leaseState:properties.lease.state}" -o json

az storage blob lease break --container-name tfstate --blob-name learnapp-dev.tfstate \
  --account-name tfstate439921213 --auth-mode login
```

**Or from GitHub:** run **Unlock Terraform State**
([.github/workflows/unlock-state.yml](.github/workflows/unlock-state.yml)) → pick the
**environment** → set **confirm** = `unlock`.

> The pipeline passes `-lock-timeout=120s`, so a stale lock fails a run after 2 minutes with a
> clear error instead of hanging. `concurrency: cancel-in-progress: false` queues overlapping
> runs per environment rather than killing them.

---

## Security properties

- **No secrets stored** — client/tenant/subscription IDs are non-sensitive identifiers.
- **Short-lived tokens** — 1-hour Azure access tokens, auto-refreshed.
- **Scoped trust** — each federated credential is locked to a specific repo + ref/environment.
- **No storage keys** — shared-key access disabled; state blobs use Azure AD auth.
- **Per-environment isolation** — separate state files, environments, and approval gates.
- **Auditable** — all access logged in Azure AD sign-in logs under the service principal.
