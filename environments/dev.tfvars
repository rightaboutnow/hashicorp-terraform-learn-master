# environments/dev.tfvars — development environment
# All deployment inputs for dev live here. The state key (learnapp-dev.tfstate)
# is set separately at `terraform init` (partial backend); see versions.tf.

# ── Identity / naming ─────────────────────────────────────────────────────────
application_name = "learnapp"
environment_name = "dev"
location         = "australiaeast"
# resource_group_name left unset → computed as rg-learnapp-dev.

# ── Ownership / governance (surface as tags) ──────────────────────────────────
owner       = "Jenson Thomas"
owner_email = "jensonzthomas@outlook.com"
cost_center = "learning-dev"

additional_tags = {
  tier          = "nonprod"
  criticality   = "low"
  auto_shutdown = "true"
  data_class    = "internal"
}

# ── Storage account ───────────────────────────────────────────────────────────
storage_account_tier              = "Standard"
storage_account_replication_type  = "LRS" # cheapest, locally-redundant for dev
storage_account_kind              = "StorageV2"
storage_min_tls_version           = "TLS1_2"
storage_allow_public_blob_access  = false
storage_shared_access_key_enabled = false

# ── Networking ────────────────────────────────────────────────────────────────
vnet_address_space = ["10.10.0.0/16"]
subnet_prefixes = {
  default = "10.10.1.0/24"
  apps    = "10.10.2.0/24"
}
