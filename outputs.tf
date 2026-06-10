# outputs.tf
# Values exposed after apply. Grouped by area. No secrets are output —
# shared-key access is disabled, so connection strings / access keys are neither
# used nor exposed.

# ──────────────────────────────────────────────────────────────────────────────
# Deployment context
# ──────────────────────────────────────────────────────────────────────────────

output "environment" {
  description = "The environment this state was deployed for (dev/test/prod)."
  value       = var.environment_name
}

output "application_name" {
  description = "The application/workload name used in resource names and the state key."
  value       = var.application_name
}

output "location" {
  description = "Azure region the resources were deployed to."
  value       = azurerm_resource_group.main.location
}

output "location_short" {
  description = "Short region code used in naming (e.g. aue for australiaeast)."
  value       = local.location_short
}

# ──────────────────────────────────────────────────────────────────────────────
# Resource group
# ──────────────────────────────────────────────────────────────────────────────

output "resource_group_name" {
  description = "Name of the created resource group."
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "Full Azure resource ID of the resource group."
  value       = azurerm_resource_group.main.id
}

# ──────────────────────────────────────────────────────────────────────────────
# Storage account
# ──────────────────────────────────────────────────────────────────────────────

output "storage_account_name" {
  description = "Name of the created storage account."
  value       = azurerm_storage_account.example.name
}

output "storage_account_id" {
  description = "Full Azure resource ID of the storage account."
  value       = azurerm_storage_account.example.id
}

output "storage_account_primary_blob_endpoint" {
  description = "Primary blob service endpoint URL."
  value       = azurerm_storage_account.example.primary_blob_endpoint
}

output "storage_account_primary_dfs_endpoint" {
  description = "Primary Data Lake (DFS) service endpoint URL."
  value       = azurerm_storage_account.example.primary_dfs_endpoint
}

output "storage_account_tier" {
  description = "Performance tier (Standard/Premium)."
  value       = azurerm_storage_account.example.account_tier
}

output "storage_account_replication_type" {
  description = "Replication strategy (LRS/ZRS/GZRS/…)."
  value       = azurerm_storage_account.example.account_replication_type
}

output "storage_account_kind" {
  description = "Storage account kind (e.g. StorageV2)."
  value       = azurerm_storage_account.example.account_kind
}

# ──────────────────────────────────────────────────────────────────────────────
# Governance
# ──────────────────────────────────────────────────────────────────────────────

output "common_tags" {
  description = "Tags applied to all resources."
  value       = local.common_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Consolidated summary (handy for `terraform output deployment_summary`)
# ──────────────────────────────────────────────────────────────────────────────

output "deployment_summary" {
  description = "Single object summarizing the key facts of this deployment."
  value = {
    environment     = var.environment_name
    application     = var.application_name
    location        = azurerm_resource_group.main.location
    location_short  = local.location_short
    resource_group  = azurerm_resource_group.main.name
    storage_account = azurerm_storage_account.example.name
    blob_endpoint   = azurerm_storage_account.example.primary_blob_endpoint
    replication     = azurerm_storage_account.example.account_replication_type
    owner           = var.owner
    cost_center     = var.cost_center
  }
}
