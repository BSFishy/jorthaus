resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
}

resource "vault_mount" "seaweedfs" {
  path        = "seaweedfs"
  type        = "kv"
  description = "SeaweedFS static configuration secrets"

  options = {
    version = "2"
  }
}

resource "vault_policy" "seaweedfs" {
  name = "seaweedfs"

  policy = <<-EOT
    path "postgres/static-creds/seaweedfs" {
      capabilities = ["read"]
    }

    path "seaweedfs/data/s3" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "seaweedfs" {
  backend        = vault_auth_backend.approle.path
  role_name      = "seaweedfs"
  token_policies = [vault_policy.seaweedfs.name]

  bind_secret_id     = true
  secret_id_ttl      = 0
  secret_id_num_uses = 0

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
