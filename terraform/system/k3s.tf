resource "vault_mount" "k3s" {
  path        = "k3s"
  type        = "kv"
  description = "k3s bootstrap secrets"

  options = {
    version = "2"
  }
}

resource "vault_policy" "k3s" {
  name = "k3s"

  policy = <<-EOT
    path "k3s/data/bootstrap" {
      capabilities = ["read"]
    }

    path "postgres/static-creds/k3s" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "k3s" {
  backend        = vault_auth_backend.approle.path
  role_name      = "k3s"
  token_policies = [vault_policy.k3s.name]

  bind_secret_id     = true
  secret_id_ttl      = 0
  secret_id_num_uses = 0

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
