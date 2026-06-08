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

[.github/workflows/terraform.yml](.github/workflows/terraform.yml) runs three jobs on every
push to `main`:

1. **Init & Validate** — `terraform init`, `fmt -check`, `validate`
2. **Plan** — `terraform plan` and uploads the plan as a CI artifact
3. **Apply** — *waits for manual approval.* The job targets the **`production`**
   environment, which has a required reviewer. The run **pauses after plan** and waits for an
   **Approve / Reject** click. Approving applies the exact plan from the Plan job; rejecting
   ends the run without changes — **no re-run needed either way**.

Each job runs `terraform init` on a fresh runner; the saved plan is passed from Plan → Apply
as an artifact so apply executes exactly what was reviewed.

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
  - `repo:<org>/<repo>:ref:refs/heads/main` — used by the init/plan jobs (and push)
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

## Security properties

- **No secrets stored** — client/tenant/subscription IDs are non-sensitive identifiers.
- **Short-lived tokens** — 1-hour Azure access tokens, auto-refreshed.
- **Scoped trust** — federated credential locked to a specific repo + branch.
- **No storage keys** — shared-key access disabled; state blob uses Azure AD auth.
- **Auditable** — all access logged in Azure AD sign-in logs under the service principal.
</content>
