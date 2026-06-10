#!/usr/bin/env bash
#
# bootstrap.sh — one-time, manual bootstrap for the Terraform + GitHub Actions + Azure
# OIDC setup. Run this once per (repo, subscription) before the deploy pipeline can work.
# It is idempotent: every resource is created only if it does not already exist, so it's
# safe to re-run.
#
# It does NOT run in the pipeline — it provisions the very things the pipeline needs to
# authenticate (the Azure AD app, federated credentials, RBAC, state storage, and the
# GitHub repo's variables + environments).
#
# ──────────────────────────────────────────────────────────────────────────────
# Prerequisites (the unavoidable "first credentials"):
#   - az CLI, logged in as a user who can create Entra app registrations and assign
#     roles  →  `az login`   (needs Application Administrator-ish + Owner/User Access Admin)
#   - gh CLI, authenticated with repo admin rights  →  `gh auth login`
#   - The GitHub repo must already exist (create it manually first).
#
# Usage:
#   GITHUB_OWNER=myorg GITHUB_REPO=myrepo ./scripts/bootstrap.sh
#   # or with more overrides:
#   GITHUB_OWNER=myorg GITHUB_REPO=myrepo APP_NAME=myapp-cicd \
#     ENVIRONMENTS="dev test prod" REVIEWED_ENVS="prod" PROD_REVIEWERS="alice bob" \
#     ./scripts/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Auto-source scripts/bootstrap.env if present, so values live in a file instead
# of being passed inline. Inline env vars still override it. Resolved relative to
# this script so it works from any directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/bootstrap.env" ]; then
  set -a; . "$SCRIPT_DIR/bootstrap.env"; set +a
fi

# ── Configuration (override any of these via environment variables) ───────────
GITHUB_OWNER="${GITHUB_OWNER:?Set GITHUB_OWNER (the GitHub org/user that owns the repo)}"
GITHUB_REPO="${GITHUB_REPO:?Set GITHUB_REPO (the repository name)}"

# Azure context — default to whatever `az` is currently logged into.
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"

# Names / settings (sensible defaults; override as needed).
APP_NAME="${APP_NAME:-github-actions-terraform}"
LOCATION="${LOCATION:-australiaeast}"
ENVIRONMENTS="${ENVIRONMENTS:-dev test prod}"      # space-separated
REVIEWED_ENVS="${REVIEWED_ENVS:-prod}"             # which envs require an approver
PROD_REVIEWERS="${PROD_REVIEWERS:-}"               # space-separated GitHub usernames

# Remote state storage (must be globally unique + stable across runs).
STATE_RG="${STATE_RG:-tfstate-rg}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
# Deterministic default name so re-runs reuse the same account (3-24 lowercase alnum).
STATE_SA="${STATE_SA:-tfstate$(printf '%s' "$SUBSCRIPTION_ID" | shasum | cut -c1-16)}"

ISSUER="https://token.actions.githubusercontent.com"
AUDIENCE="api://AzureADTokenExchange"

# ── Pretty logging ────────────────────────────────────────────────────────────
bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
log()  { printf '%s\n' "${bold}==>${reset} $*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
skip() { printf '    • %s (already exists)\n' "$*"; }
warn() { printf '    ⚠ %s\n' "$*" >&2; }

# ── Preflight checks ──────────────────────────────────────────────────────────
log "Preflight checks"
command -v az >/dev/null || { echo "az CLI not found"; exit 1; }
command -v gh >/dev/null || { echo "gh CLI not found"; exit 1; }
az account show >/dev/null 2>&1 || { echo "Not logged into Azure — run 'az login'"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged into GitHub — run 'gh auth login'"; exit 1; }
gh repo view "$GITHUB_OWNER/$GITHUB_REPO" >/dev/null 2>&1 \
  || { echo "Repo $GITHUB_OWNER/$GITHUB_REPO not found/accessible — create it first"; exit 1; }
ok "az logged in, gh authenticated, repo reachable"

cat <<SUMMARY

  Repo            : $GITHUB_OWNER/$GITHUB_REPO
  Subscription    : $SUBSCRIPTION_ID
  Tenant          : $TENANT_ID
  App name        : $APP_NAME
  Environments    : $ENVIRONMENTS   (reviewers on: $REVIEWED_ENVS)
  State storage   : $STATE_SA / $STATE_CONTAINER  (RG $STATE_RG, $LOCATION)

SUMMARY

# ── 1. Azure AD application + service principal ───────────────────────────────
log "1. Azure AD application + service principal"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  ok "created app registration ($APP_ID)"
else
  skip "app registration ($APP_ID)"
fi

if ! az ad sp show --id "$APP_ID" >/dev/null 2>&1; then
  az ad sp create --id "$APP_ID" >/dev/null
  ok "created service principal"
else
  skip "service principal"
fi
SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
ok "service principal object id: $SP_ID"

# ── 2. Federated identity credentials (OIDC) ──────────────────────────────────
log "2. Federated credentials (main + per environment)"
existing_subjects=$(az ad app federated-credential list --id "$APP_ID" --query "[].subject" -o tsv)

create_fic() {
  local name="$1" subject="$2"
  if printf '%s\n' "$existing_subjects" | grep -qxF "$subject"; then
    skip "$name → $subject"
  else
    az ad app federated-credential create --id "$APP_ID" --parameters \
      "{\"name\":\"$name\",\"issuer\":\"$ISSUER\",\"subject\":\"$subject\",\"audiences\":[\"$AUDIENCE\"]}" >/dev/null
    ok "$name → $subject"
  fi
}

create_fic "github-main" "repo:$GITHUB_OWNER/$GITHUB_REPO:ref:refs/heads/main"
for env in $ENVIRONMENTS; do
  create_fic "github-env-$env" "repo:$GITHUB_OWNER/$GITHUB_REPO:environment:$env"
done

# ── 3. RBAC role assignments (subscription scope) ─────────────────────────────
log "3. RBAC role assignments (subscription scope)"
SUB_SCOPE="/subscriptions/$SUBSCRIPTION_ID"
assign_role() {
  local role="$1" scope="$2"
  if [ -n "$(az role assignment list --assignee "$SP_ID" --role "$role" --scope "$scope" --query "[0].id" -o tsv 2>/dev/null)" ]; then
    skip "$role"
  else
    az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" >/dev/null
    ok "$role"
  fi
}
assign_role "Contributor"                   "$SUB_SCOPE"
assign_role "User Access Administrator"     "$SUB_SCOPE"
assign_role "Storage Blob Data Contributor" "$SUB_SCOPE"

# ── 4. Remote state storage (RG + account + container) ────────────────────────
log "4. Remote state storage"
az group create --name "$STATE_RG" --location "$LOCATION" >/dev/null
ok "resource group $STATE_RG"

if az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" >/dev/null 2>&1; then
  skip "storage account $STATE_SA"
else
  az storage account create \
    --name "$STATE_SA" --resource-group "$STATE_RG" --location "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false --allow-shared-key-access false --https-only true >/dev/null
  ok "storage account $STATE_SA (shared-key disabled)"
fi

# The admin running this needs data-plane access to create the container (shared key is off).
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
SA_SCOPE="$SUB_SCOPE/resourceGroups/$STATE_RG/providers/Microsoft.Storage/storageAccounts/$STATE_SA"
if [ -n "$CURRENT_USER_ID" ]; then
  if [ -z "$(az role assignment list --assignee "$CURRENT_USER_ID" --role "Storage Blob Data Contributor" --scope "$SA_SCOPE" --query "[0].id" -o tsv 2>/dev/null)" ]; then
    az role assignment create --assignee-object-id "$CURRENT_USER_ID" --assignee-principal-type User \
      --role "Storage Blob Data Contributor" --scope "$SA_SCOPE" >/dev/null
    ok "granted yourself Storage Blob Data Contributor on the state account"
  fi
else
  warn "could not resolve signed-in user (logged in as SP?) — container create may need data-plane access"
fi

# Create the container (retry: RBAC takes a moment to propagate).
log "   creating state container '$STATE_CONTAINER' (Azure AD auth)"
for attempt in 1 2 3 4 5 6; do
  if az storage container create --name "$STATE_CONTAINER" --account-name "$STATE_SA" \
       --auth-mode login >/dev/null 2>&1; then
    ok "container $STATE_CONTAINER"
    break
  fi
  [ "$attempt" -eq 6 ] && { warn "container create still failing — re-run in ~1 min (RBAC propagation)"; break; }
  sleep 10
done

# ── 5. GitHub Actions variables ───────────────────────────────────────────────
log "5. GitHub Actions repository variables"
set_var() { gh variable set "$1" -R "$GITHUB_OWNER/$GITHUB_REPO" --body "$2" >/dev/null && ok "$1=$2"; }
set_var AZURE_CLIENT_ID         "$APP_ID"
set_var AZURE_TENANT_ID         "$TENANT_ID"
set_var AZURE_SUBSCRIPTION_ID   "$SUBSCRIPTION_ID"
set_var TFSTATE_RESOURCE_GROUP  "$STATE_RG"
set_var TFSTATE_STORAGE_ACCOUNT "$STATE_SA"
set_var TFSTATE_CONTAINER       "$STATE_CONTAINER"

# ── 6. GitHub Environments (+ required reviewers) ─────────────────────────────
log "6. GitHub Environments"
# Resolve reviewer usernames → numeric IDs once.
reviewer_json=""
if [ -n "$PROD_REVIEWERS" ]; then
  parts=""
  for u in $PROD_REVIEWERS; do
    uid=$(gh api "users/$u" --jq .id 2>/dev/null || true)
    [ -n "$uid" ] && parts="${parts:+$parts,}{\"type\":\"User\",\"id\":$uid}" || warn "reviewer '$u' not found"
  done
  [ -n "$parts" ] && reviewer_json="[$parts]"
fi

for env in $ENVIRONMENTS; do
  needs_reviewer=false
  for r in $REVIEWED_ENVS; do [ "$r" = "$env" ] && needs_reviewer=true; done
  env_exists=false
  gh api "repos/$GITHUB_OWNER/$GITHUB_REPO/environments/$env" >/dev/null 2>&1 && env_exists=true

  if $needs_reviewer && [ -n "$reviewer_json" ]; then
    # Apply/refresh required reviewers (idempotent).
    gh api -X PUT "repos/$GITHUB_OWNER/$GITHUB_REPO/environments/$env" \
      -H "Accept: application/vnd.github+json" \
      --input - >/dev/null <<JSON
{"reviewers": $reviewer_json}
JSON
    ok "environment '$env' (required reviewers set)"
  elif ! $env_exists; then
    # Create the environment only if missing — never clobber an existing one's protection.
    gh api -X PUT "repos/$GITHUB_OWNER/$GITHUB_REPO/environments/$env" >/dev/null
    if $needs_reviewer; then
      warn "environment '$env' created WITHOUT a reviewer (no PROD_REVIEWERS given, or required reviewers need GitHub Pro on a private repo) — apply would run unattended"
    else
      ok "environment '$env'"
    fi
  else
    skip "environment '$env'"
  fi
done

# ── Done ──────────────────────────────────────────────────────────────────────
cat <<DONE

${bold}Bootstrap complete.${reset}

  App (client) id : $APP_ID
  SP object id    : $SP_ID
  State backend   : RG=$STATE_RG  account=$STATE_SA  container=$STATE_CONTAINER

Next steps:
  1. Point the Terraform backend at this state account. Either set in versions.tf:
       storage_account_name = "$STATE_SA"
       resource_group_name  = "$STATE_RG"
       container_name       = "$STATE_CONTAINER"
     (or pass them via -backend-config; the values are also stored as the
      TFSTATE_* GitHub variables above).
  2. Push the code to the repo's default branch (main).
  3. Run the "Terraform Apply" workflow and pick an environment.

Re-running this script is safe — existing resources are skipped.
DONE
