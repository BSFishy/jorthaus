resource "vault_mount" "metal" {
  path        = "metal"
  type        = "kv"
  description = "Static host and service secrets rendered by NixOS OpenBao Agents"

  options = {
    version = "2"
  }
}

resource "vault_policy" "metal_agent" {
  name = "metal-agent"

  policy = <<-EOT
    path "metal/data/*" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "metal_agent" {
  backend        = vault_auth_backend.approle.path
  role_name      = "metal-agent"
  token_policies = [vault_policy.metal_agent.name]

  bind_secret_id     = true
  secret_id_ttl      = 0
  secret_id_num_uses = 0

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
