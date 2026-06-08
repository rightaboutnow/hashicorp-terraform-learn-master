# terrazlearn — Terraform on Azure with GitHub Actions (OIDC)

A learning project for managing Azure infrastructure with Terraform, deployed through
GitHub Actions using **OpenID Connect (OIDC)** — no client secrets or storage keys stored
anywhere. State lives in an Azure Blob container authenticated with Azure AD.

```
GitHub Actions → OIDC JWT → Azure AD validates → short-lived token (1h) → Azure APIs
```

---

## Repository layout

| File | Purpose |
|------|---------|
| [versions.tf](versions.tf) | Terraform & `azurerm` provider versions + the remote state backend |
| [main.tf](main.tf) | Your Azure resources (skeleton — add as you learn) |
| [variables.tf](variables.tf) | Input variables (location, resource group name, tags) |
| [outputs.tf](outputs.tf) | Output values (skeleton) |
| [.github/workflows/terraform.yml](.github/workflows/terraform.yml) | CI/CD pipeline: init → plan → apply |
| [.gitignore](.gitignore) | Excludes `.terraform/`, state, plan, and `*.tfvars` |
| [.terraform.lock.hcl](.terraform.lock.hcl) | Provider dependency lock (committed) |
| [github-actions-azure-terraform-oidc.md](github-actions-azure-terraform-oidc.md) | One-time Azure/GitHub setup guide |
| [VALIDATION.md](VALIDATION.md) | Commands to validate the whole setup |

---

## Tooling versions

| Component | Version |
|-----------|---------|
| Terraform | `>= 1.15.0` (CI pins `~1.15`) |
| azurerm provider | `~> 4.76` (locked at 4.76.0) |
| actions/checkout | v6 |
| azure/login | v3 |
| hashicorp/setup-terraform | v4 |
| actions/upload-artifact | v7 |
| actions/download-artifact | v8 |

---

## How the pipeline works

[.github/workflows/terraform.yml](.github/workflows/terraform.yml) runs two jobs on every
push to `main`:

1. **Plan** — `terraform init`, `fmt -check`, `validate`, then `terraform plan`; uploads the
   plan as a CI artifact. (Init, validation, and plan are combined into one job since they're
   sequential and share state — one runner, one `init`.)
2. **Apply** — *waits for manual approval.* The job targets the **`production`**
   environment, which has a required reviewer. The run **pauses after plan** and waits for an
   **Approve / Reject** click. Approving applies the exact plan from the Plan job; rejecting
   ends the run without changes — **no re-run needed either way**.

Apply runs on a fresh runner, so it re-runs `terraform init`; the saved plan is passed from
Plan → Apply as an artifact so apply executes exactly what was reviewed.

### Choosing whether to apply (the approval gate)

Every run (push to `main` or manual **Run workflow**) does init → plan, then stops at the
apply job pending approval:

1. Open the run under the **Actions** tab. After Plan finishes you'll see **Review
   deployments** / a yellow "Waiting" badge on the Apply job.
2. Review the plan output in the Plan job's logs.
3. Click **Review deployments** → tick **production** → **Approve and deploy** to apply, or
   **Reject** to stop. Reviewers are also emailed/notified when a run is waiting.

Approvals time out after a configurable window (default 30 days). Approving/rejecting acts on
the *same* run — the plan is never recomputed, so apply uses exactly what you reviewed.

> **One-time setup** of the `production` environment (required reviewer) is described under
> [Prerequisites](#prerequisites). Without it the apply job would run unattended.

---

## Prerequisites

The Azure/GitHub trust must be provisioned once before the pipeline can run — full steps in
[github-actions-azure-terraform-oidc.md](github-actions-azure-terraform-oidc.md). In short:

- An Azure AD **app registration** + **service principal** (`github-actions-terraform`)
- **Federated credentials** trusting these OIDC subjects:
  - `repo:<org>/<repo>:ref:refs/heads/main` — used by the plan job (and push)
  - `repo:<org>/<repo>:environment:production` — used by the **apply** job (the environment
    changes the token subject; without this credential apply's Azure login fails)
  - `repo:<org>/<repo>:pull_request` — optional, for plan-only PR runs
- **RBAC**: `Contributor` (+ `User Access Administrator` if Terraform manages role
  assignments) on the subscription, and `Storage Blob Data Contributor` on the state storage
  account
- A **state storage account** + blob container (shared-key access disabled → Azure AD only)
- Three **GitHub Actions variables**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_SUBSCRIPTION_ID`
- A **GitHub Environment named `production`** with a **required reviewer** — this is what
  makes apply pause for approval.

### Create the `production` environment + federated credential

**GitHub Environment (UI):** repo → **Settings** → **Environments** → **New environment** →
name it `production` → enable **Required reviewers** → add yourself → **Save**.

**GitHub Environment (gh CLI):**

```bash
# Required reviewers via the REST API (replace USER_ID with your numeric GitHub user id:
#   gh api user --jq .id   )
gh api -X PUT repos/rightaboutnow/terraform-learn/environments/production \
  -f "reviewers[][type]=User" -F "reviewers[][id]=USER_ID"
```

**Azure federated credential for the environment** (already created for this project):

```bash
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-env-production",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:rightaboutnow/terraform-learn:environment:production",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

To validate all of the above, see [VALIDATION.md](VALIDATION.md).

---

## Local development

Requires the Terraform CLI and Azure CLI (`az login`).

```bash
# Format and validate without touching the remote backend
terraform fmt -recursive
terraform init -backend=false
terraform validate

# Full init against the real backend (needs az login / OIDC)
terraform init
terraform plan
```

> `apply` is intentionally left to the CI pipeline. Run it locally only if you know what you
> are doing.

---

## First-time deployment checklist

Do these **in order**. The ordering matters: the approval gate isn't active until the GitHub
Environment exists, so create it before (or immediately after) the first push — otherwise the
very first run will **apply unattended**.

1. **Provision the Azure side** (one-time) — app/SP, federated credentials, RBAC, state
   storage. See [github-actions-azure-terraform-oidc.md](github-actions-azure-terraform-oidc.md)
   and confirm with [VALIDATION.md](VALIDATION.md). Make sure the
   `repo:<org>/<repo>:environment:production` federated credential exists (see
   [Prerequisites](#prerequisites)).
2. **Set the three GitHub Actions variables** — `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_SUBSCRIPTION_ID` (repo → Settings → Secrets and variables → Actions → Variables).
3. **Create the `production` Environment with a required reviewer** — repo → Settings →
   Environments → New environment → `production` → enable **Required reviewers** → add
   yourself → Save. ⚠️ **Skip this and apply runs with no approval.**
4. **Push the code to `main`** — see [Git commands](#git-commands) below. This starts the
   first run.
5. **Watch the run** — init → plan run automatically; the apply job then **pauses** for
   approval (see [the approval gate](#choosing-whether-to-apply-the-approval-gate)).
6. **Review the plan, then Approve or Reject** — Approve applies the exact plan; Reject ends
   the run with no changes.

Quick verification before pushing:

```bash
# Environment exists with a reviewer (needs gh CLI)
gh api repos/rightaboutnow/terraform-learn/environments/production \
  --jq '.name, .protection_rules'

# Actions variables are set
gh variable list -R rightaboutnow/terraform-learn

# Azure federated credential for the environment exists
az ad app federated-credential list --id "$APP_ID" \
  --query "[?contains(subject,'environment:production')].{name:name, subject:subject}" -o table
```

---

## Git commands

### First-time setup — initialize and push

Run from the repo root. **Pushing to `main` triggers the workflow** (init + plan; apply stays
manual).

```bash
# Initialize the local repo on the main branch
git init -b main

# Stage everything (.gitignore excludes .terraform/, state, tfplan, *.tfvars)
git add .

# First commit
git commit -m "Terraform + GitHub Actions Azure OIDC pipeline"

# Add the remote over SSH
git remote add origin git@github.com:rightaboutnow/terraform-learn.git

# Push and set the upstream — this starts the Terraform workflow
git push -u origin main
```

### Everyday workflow

```bash
# Check what changed
git status
git diff

# Stage, commit, push
git add <files>          # or: git add -A
git commit -m "Describe the change"
git push                 # pushes to origin/main → runs init + plan
```

### Working on a branch (recommended for changes)

```bash
# Create and switch to a feature branch
git switch -c feature/add-resource-group

# ...edit files...
git add -A
git commit -m "Add resource group"
git push -u origin feature/add-resource-group

# Open a PR on GitHub, review the plan, then merge to main to deploy
```

### Inspecting the remote

```bash
# Confirm SSH identity
ssh -T git@github.com

# List branches/refs on the remote (empty output = nothing pushed yet)
git ls-remote git@github.com:rightaboutnow/terraform-learn.git

# Show configured remotes
git remote -v
```

### Useful housekeeping

```bash
git log --oneline -10        # recent history
git pull --rebase            # sync with remote before pushing
git restore <file>           # discard local changes to a file
git restore --staged <file>  # unstage a file
```

---

## Watching a run (optional, needs `gh`)

```bash
# Install + authenticate the GitHub CLI
brew install gh
gh auth login

# Confirm the Actions variables are set before the first run
gh variable list -R rightaboutnow/terraform-learn

# List and watch workflow runs
gh run list   -R rightaboutnow/terraform-learn
gh run watch  -R rightaboutnow/terraform-learn
```

---

## Troubleshooting

### Run hangs on "Acquiring state lock. This may take a few moments…"

The `azurerm` backend locks state by holding a **blob lease** on `terraform.tfstate`. If a run
is **cancelled mid-`init`/`plan`/`apply`**, Terraform never releases the lease, so the next run
blocks forever waiting for a lock no live process owns.

**Check the lease:**

```bash
az storage blob show --container-name tfstate --name terraform.tfstate \
  --account-name tfstate439921213 --auth-mode login \
  --query "{leaseStatus:properties.lease.status, leaseState:properties.lease.state, lastModified:properties.lastModified}" -o json
```

`leaseState: leased` / `leaseStatus: locked` with no run actively using it = stale lock.

**Break it** (only releases the lock — does not modify state contents):

```bash
az storage blob lease break --container-name tfstate --blob-name terraform.tfstate \
  --account-name tfstate439921213 --auth-mode login
```

**Or from GitHub** (no local `az` needed): run the **Unlock Terraform State** workflow
([.github/workflows/unlock-state.yml](.github/workflows/unlock-state.yml)) — Actions → *Unlock
Terraform State* → Run workflow → set **confirm** = `unlock`. It shows the lease state, breaks
it, and confirms it's unlocked.

Alternatively, if you have the lock ID from Terraform's error message:
`terraform force-unlock <LOCK_ID>` (run locally against the same backend).

Then **cancel the stuck GitHub run and re-run it** — it will acquire the now-free lock
immediately. (The management-plane `az` commands above are not affected by the lock, so you can
always run them.)

> The pipeline also passes `-lock-timeout=120s` to `plan`/`apply`, so a stale lock makes a run
> **fail after 2 minutes** with a clear error instead of hanging indefinitely.

> Prevention: avoid cancelling a run while it's mid-Terraform. The workflow's
> `concurrency: cancel-in-progress: false` queues overlapping runs rather than killing them, so
> a stuck run holds up the queue until the lock is cleared.

---

## Security properties

- **No secrets stored** — client/tenant/subscription IDs are non-sensitive identifiers.
- **Short-lived tokens** — 1-hour Azure access tokens, auto-refreshed.
- **Scoped trust** — federated credential locked to a specific repo + branch.
- **No storage keys** — shared-key access disabled; state blob uses Azure AD auth.
- **Auditable** — all access logged in Azure AD sign-in logs under the service principal.
</content>
