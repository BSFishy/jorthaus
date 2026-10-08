resource "b2_bucket" "victorialogs_backups" {
  bucket_name = var.victorialogs_backup_bucket_name
  bucket_type = "allPrivate"

  default_server_side_encryption {
    algorithm = "AES256"
    mode      = "SSE-B2"
  }

  lifecycle_rules {
    file_name_prefix = var.victorialogs_backup_restic_prefix

    days_from_starting_to_canceling_unfinished_large_files = 7
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "b2_application_key" "victorialogs_backups" {
  key_name = "jorthaus-victorialogs-restic-backup"

  bucket_ids  = [b2_bucket.victorialogs_backups.bucket_id]
  name_prefix = var.victorialogs_backup_restic_prefix

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

resource "random_password" "victorialogs_backup_restic" {
  length  = 64
  special = false
}

resource "vault_kv_secret_v2" "victorialogs_backup" {
  mount = vault_mount.backup.path
  name  = "victorialogs"

  data_json = jsonencode({
    b2_application_key_id = b2_application_key.victorialogs_backups.application_key_id
    b2_application_key    = b2_application_key.victorialogs_backups.application_key
    restic_password       = random_password.victorialogs_backup_restic.result
  })
}

resource "vault_policy" "victorialogs_backup" {
  name = "victorialogs-backup"

  policy = <<-EOT
    path "backup/data/victorialogs" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "victorialogs_backup" {
  backend        = vault_auth_backend.approle.path
  role_name      = "victorialogs-backup"
  token_policies = [vault_policy.victorialogs_backup.name]

  bind_secret_id     = true
  secret_id_ttl      = 0
  secret_id_num_uses = 0

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
