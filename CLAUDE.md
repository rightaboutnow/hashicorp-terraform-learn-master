# CLAUDE.md

Guidance for AI agents (Claude Code) working in this repository. Read this first; it captures
the architecture and the non-obvious rules that aren't visible from any single file.

## What this is

A learning project for managing **Azure** infrastructure with **Terraform**, deployed via
**GitHub Actions** using **OIDC** (workload identity federation) — no client secrets or storage
keys are stored anywhere. Terraform state lives in an Azure Blob container, authenticated with
Azure AD. The repo is `rightaboutnow/terraform-learn` (subscription `terraform-test`).

## Repository map

| Path | What it is |
|------|------------|
| `versions.tf` | Terraform `>= 1.15.0`, providers (`azurerm ~> 4.76`, `random 3.9.0`), and the **partial** `azurerm` backend |
| `main.tf` | Resources: a resource group + a storage account, names/tags computed in `locals` |
| `variables.tf` | All inputs, many with `validation {}` blocks; per-env values come from tfvars |
| `outputs.tf` | environment, RG name, location, storage account name, common tags |
| `environments/{dev,test,prod}.tfvars` | Per-environment settings (committed — no secrets) |
| `.github/workflows/terraform-apply.yml` | Manual deploy: pick env → plan → approve → apply |
| `.github/workflows/terraform-destroy.yml` | Manual teardown: pick env → plan-destroy → approve → destroy |
| `.github/workflows/unlock-state.yml` | Manual: break a stale state-lock lease for one env |
| `scripts/bootstrap.sh` + `scripts/bootstrap.env` | Idempotent one-time provisioning of all prerequisites; config in the `.env` |
| `SETUP.md` | Run the bootstrap + architecture reference (what the setup is and why) |
| `VALIDATION.md` | Copy-paste commands to validate the live setup (+ the real IDs) |
| `README.md` | Human-facing overview |

## The multi-environment model (most important concept)

One Terraform root config serves **dev / test / prod**. The environment is selected at run time,
and it drives **three** things that must stay in sync:

1. **State file** — the backend is **partial**: `versions.tf` omits `key`. Each env's state is a
   separate blob, set at init: `terraform init -backend-config="key=<app>-<env>.tfstate"`.
   The workflows derive `<app>` by reading `application_name` from
   `environments/<env>.tfvars` (single source of truth — not hardcoded), expose it as the
   `state_key` job output, and reuse it across jobs. Never hardcode `key` back into `versions.tf`.
2. **Variables** — `-var-file="environments/<env>.tfvars"` on plan.
3. **Approval + OIDC identity** — the apply/destroy jobs set `environment: <env>` (a GitHub
   Environment). That both gates on the env's protection rules **and** changes the OIDC token
   subject to `repo:<org>/<repo>:environment:<env>`, which must have a matching Azure federated
   credential (`github-env-<env>`). The `plan` job has no `environment:` and uses the
   `github-main` credential (subject `…:ref:refs/heads/main`).

`concurrency.group` is `terraform-<env>`, so a dev run never blocks a prod run, and apply +
destroy for the same env can't run simultaneously.

## Auth model

- OIDC only. The `ARM_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID` + `ARM_USE_OIDC=true` env vars
  (sourced from GitHub Actions **variables**, not secrets) authenticate the **Terraform**
  azurerm provider/backend.
- The separate `azure/login@v3` step authenticates the **`az` CLI** (used by the unlock
  workflow and as a fail-fast OIDC check). The two logins are independent.
- IDs are non-sensitive identifiers; they're intentionally committed (see `VALIDATION.md`). There
  are still **no secrets** in the repo. Don't introduce client secrets or storage access keys.

## Common commands

```bash
# Local validation (no Azure auth, no backend)
terraform fmt -recursive
terraform init -backend=false
terraform validate

# Full local init against the real backend (needs `az login`); pick the env's state key
terraform init -backend-config="key=learnapp-dev.tfstate"
terraform plan -var-file="environments/dev.tfvars"

# Validate the live Azure/GitHub setup
#   → follow VALIDATION.md
```

Deploys/destroys run **only via the GitHub Actions workflows** (manual `workflow_dispatch`).
Don't run `terraform apply` locally against the real backend unless explicitly asked.

## Conventions

- **Formatting:** `terraform fmt` is enforced in CI (`fmt -check`). `.vscode/settings.json` turns
  on format-on-save. Always leave HCL `fmt`-clean.
- **Naming:** resource names are computed in `main.tf` `locals` (e.g. `rg-<app>-<env>`). The
  storage account name is `substr(prefix, 0, 12) + 12-char random suffix` to stay within Azure's
  **24-char, lowercase-alphanumeric** limit — keep that invariant if you touch naming.
- **Variables:** prefer adding a typed variable with a `validation {}` block over hardcoding;
  put per-env values in the tfvars files, not in defaults.
- **Docs stay in sync:** workflow/behavior changes should be reflected in `README.md` (and
  `SETUP.md`/`VALIDATION.md` where relevant). `SETUP.md` summarizes the workflow rather than
  duplicating the YAML — keep it that way to avoid drift.

## Gotchas / hard-won knowledge

- **Run stuck on "Acquiring state lock"** = a stale blob lease from a cancelled run. Fix with the
  **Unlock Terraform State** workflow (or `az storage blob lease break` on
  `learnapp-<env>.tfstate`). Never auto-break leases inside the deploy pipeline — it would smash a
  legitimately running apply's lock. `plan`/`apply` already pass `-lock-timeout=120s` to fail fast.
- **GitHub Environment protection rules** (required reviewers) need a **public repo** or **GitHub
  Pro/Team/Enterprise**. Without the rule, `environment:` does not pause — apply runs unattended.
- **Adding a new environment** means: a tfvars file, a GitHub Environment, a `github-env-<env>`
  federated credential, and adding it to the workflow `choice` options. All four, or OIDC/approval
  breaks.
- **Workflow edits only take effect once on the repo's default branch** — `gh workflow run` and the
  Actions UI read the workflow from the branch, not your local files.
- **State isolation is sacred.** Never point two environments (or a clone for another
  subscription) at the same state `key`. Cloning to a new repo/subscription is automated by
  `scripts/bootstrap.sh` (new app/SP, federated creds, RBAC, state storage, Actions variables,
  environments) — see `SETUP.md`.
- The **state storage account** (`tfstate439921213` / RG `tfstate-rg`) is bootstrapped **outside**
  Terraform. `terraform destroy` never touches it.
- **`403 Key based authentication is not permitted`** on storage apply = the account has
  `shared_access_key_enabled = false`, so the provider must use Azure AD for the data plane. Two
  requirements (both already in place): the provider sets `storage_use_azuread = true`
  (`versions.tf`), and the deploy SP holds **Storage Blob Data Contributor** at subscription scope
  (management-plane `Contributor` does NOT grant blob data access). New storage accounts inherit
  this from the subscription-scoped grant.

## Safety rules for agents

- Treat `apply`, `destroy`, and any `az`/`gh` write as outward-facing — confirm before running,
  and never trigger a real deploy/destroy without explicit user intent.
- Don't commit or push unless asked. The repo may be empty/unpushed; pushing to `main` triggers
  real runs.
- Don't weaken the security posture: no secrets, keep `shared_access_key_enabled = false`, keep
  public blob access off, keep OIDC.
