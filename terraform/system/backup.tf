resource "vault_mount" "backup" {
  path        = "backup"
  type        = "kv"
  description = "Backup storage credentials"

  options = {
    version = "2"
  }
}

resource "vault_policy" "postgres_wal_g" {
  name = "postgres-wal-g"

  policy = <<-EOT
    path "backup/data/postgres" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "postgres_backup_csi" {
  name = "postgres-backup-csi"

  policy = <<-EOT
    path "backup/data/postgres" {
      capabilities = ["read"]
    }

    path "postgres/static-creds/postgres-backup" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "postgres_wal_g" {
  backend        = vault_auth_backend.approle.path
  role_name      = "postgres-wal-g"
  token_policies = [vault_policy.postgres_wal_g.name]

  bind_secret_id     = true
  secret_id_ttl      = 0
  secret_id_num_uses = 0

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}

resource "vault_kubernetes_auth_backend_role" "postgres_backup" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "postgres-backup"
  bound_service_account_names      = ["postgres-backup"]
  bound_service_account_namespaces = ["postgres-backup"]
  audience                         = "vault"
  token_policies                   = [vault_policy.postgres_backup_csi.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
