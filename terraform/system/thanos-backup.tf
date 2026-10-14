resource "b2_bucket" "thanos_backups" {
  bucket_name = var.thanos_backup_bucket_name
  bucket_type = "allPrivate"

  default_server_side_encryption {
    algorithm = "AES256"
    mode      = "SSE-B2"
  }

  lifecycle_rules {
    file_name_prefix = ""

    days_from_hiding_to_deleting                           = 7
    days_from_starting_to_canceling_unfinished_large_files = 7
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "b2_application_key" "thanos_backups" {
  key_name = "jorthaus-thanos-block-backup"

  bucket_ids = [b2_bucket.thanos_backups.bucket_id]

  capabilities = [
    "deleteFiles",
    "listBuckets",
    "listFiles",
    "readFiles",
    "writeFiles",
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "b2_application_key" "thanos_backup_restore_readonly" {
  key_name = "jorthaus-thanos-block-backup-restore-readonly"

  bucket_ids = [b2_bucket.thanos_backups.bucket_id]

  capabilities = [
    "listBuckets",
    "listFiles",
    "readFiles",
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_kv_secret_v2" "thanos_block_backup" {
  mount = vault_mount.backup.path
  name  = "thanos-block-replication"

  data_json = jsonencode({
    access_key_id     = b2_application_key.thanos_backups.application_key_id
    secret_access_key = b2_application_key.thanos_backups.application_key
    bucket_name       = b2_bucket.thanos_backups.bucket_name
    endpoint          = var.thanos_backup_s3_endpoint
    region            = var.thanos_backup_aws_region
  })
}

resource "vault_kv_secret_v2" "thanos_backup_restore_readonly" {
  mount = vault_mount.backup.path
  name  = "thanos-block-backup-restore-readonly"

  data_json = jsonencode({
    access_key_id     = b2_application_key.thanos_backup_restore_readonly.application_key_id
    secret_access_key = b2_application_key.thanos_backup_restore_readonly.application_key
    bucket_name       = b2_bucket.thanos_backups.bucket_name
    endpoint          = var.thanos_backup_s3_endpoint
    region            = var.thanos_backup_aws_region
  })
}

resource "vault_policy" "thanos_block_backup" {
  name = "thanos-block-backup"

  policy = <<-EOT
    path "backup/data/thanos-block-replication" {
      capabilities = ["read"]
    }

    path "seaweedfs/data/s3/bindings/thanos-backup-source" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "thanos_block_backup" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "thanos-block-backup"
  bound_service_account_names      = ["thanos-block-backup"]
  bound_service_account_namespaces = ["thanos"]
  audience                         = "vault"
  token_policies                   = [vault_policy.thanos_block_backup.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}

resource "vault_policy" "thanos_block_restore_readonly" {
  name = "thanos-block-restore-readonly"

  policy = <<-EOT
    path "backup/data/thanos-block-backup-restore-readonly" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "thanos_block_restore_readonly" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "thanos-block-restore-readonly"
  bound_service_account_names      = ["thanos-block-restore-readonly"]
  bound_service_account_namespaces = ["thanos"]
  audience                         = "vault"
  token_policies                   = [vault_policy.thanos_block_restore_readonly.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
