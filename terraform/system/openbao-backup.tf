resource "b2_bucket" "openbao_backups" {
  bucket_name = var.openbao_backup_bucket_name
  bucket_type = "allPrivate"

  default_server_side_encryption {
    algorithm = "AES256"
    mode      = "SSE-B2"
  }

  lifecycle_rules {
    file_name_prefix = var.openbao_backup_restic_prefix

    days_from_starting_to_canceling_unfinished_large_files = 7
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "b2_application_key" "openbao_backups" {
  key_name = "jorthaus-openbao-restic-backup"

  bucket_ids  = [b2_bucket.openbao_backups.bucket_id]
  name_prefix = var.openbao_backup_restic_prefix

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

resource "vault_policy" "openbao_raft_backup" {
  name = "openbao-raft-backup"

  policy = <<-EOT
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "openbao_raft_backup" {
  backend        = vault_auth_backend.approle.path
  role_name      = "openbao-raft-backup"
  token_policies = [vault_policy.openbao_raft_backup.name]

  bind_secret_id     = true
  secret_id_ttl      = 0
  secret_id_num_uses = 0

  token_no_default_policy = true
  token_type              = "service"
  token_period            = 86400
  token_ttl               = 3600
  token_max_ttl           = 14400
}
