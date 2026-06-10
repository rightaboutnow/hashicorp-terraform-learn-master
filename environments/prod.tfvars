# environments/prod.tfvars — production environment
# All deployment inputs for prod live here. The state key (learnapp-prod.tfstate)
# is set separately at `terraform init` (partial backend); see versions.tf.

# ── Identity / naming ─────────────────────────────────────────────────────────
application_name = "learnapp"
environment_name = "prod"
location         = "australiaeast"
# resource_group_name left unset → computed as rg-learnapp-prod.

# ── Ownership / governance (surface as tags) ──────────────────────────────────
owner       = "Jenson Thomas"
owner_email = "jensonzthomas@outlook.com"
cost_center = "learning-prod"

additional_tags = {
  tier        = "prod"
  criticality = "high"
  data_class  = "confidential"
}

# ── Storage account ───────────────────────────────────────────────────────────
storage_account_tier              = "Standard"
storage_account_replication_type  = "LRS"
storage_account_kind              = "StorageV2"
storage_min_tls_version           = "TLS1_2"
storage_allow_public_blob_access  = false
storage_shared_access_key_enabled = false

# ── Networking ────────────────────────────────────────────────────────────────
vnet_address_space = ["10.30.0.0/16"]
subnet_prefixes = {
  default = "10.30.1.0/24"
  apps    = "10.30.2.0/24"
}
