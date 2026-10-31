resource "vault_mount" "nats_secrets" {
  path           = "nats-secrets"
  type           = "openbao-plugin-secrets-nats"
  description    = "NATS account and user credentials"
  plugin_version = "v1.11.0"
}

locals {
  nats_route_nodes = {
    gaia-01 = "gaia-01.node.jort.haus"
    gaia-02 = "gaia-02.node.jort.haus"
    gaia-03 = "gaia-03.node.jort.haus"
  }
}

resource "vault_mount" "nats_pki" {
  path                      = "nats-pki"
  type                      = "pki"
  description               = "NATS route mutual-TLS certificates"
  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = 315360000
}

resource "vault_pki_secret_backend_root_cert" "nats_pki" {
  backend     = vault_mount.nats_pki.path
  type        = "internal"
  common_name = "Jorthaus NATS Route CA"
  ttl         = "87600h"
  key_type    = "ec"
  key_bits    = 256
}

resource "vault_pki_secret_backend_role" "nats_route" {
  for_each = local.nats_route_nodes

  backend                     = vault_mount.nats_pki.path
  name                        = "route-${each.key}"
  ttl                         = "720h"
  max_ttl                     = "2160h"
  allowed_domains             = [each.value]
  allow_bare_domains          = true
  allow_subdomains            = false
  allow_glob_domains          = false
  allow_ip_sans               = false
  allow_localhost             = false
  allow_wildcard_certificates = false
  enforce_hostnames           = true
  require_cn                  = true
  use_csr_common_name         = true
  use_csr_sans                = true
  server_flag                 = true
  client_flag                 = true
  key_type                    = "ec"
  key_bits                    = 256
}

resource "vault_policy" "nats_route_signer" {
  for_each = local.nats_route_nodes

  name = "nats-route-${each.key}"

  policy = <<-EOT
    path "nats-pki/sign/route-${each.key}" {
      capabilities = ["update"]
    }

  EOT
}

resource "vault_approle_auth_backend_role" "nats_route_signer" {
  for_each = local.nats_route_nodes

  backend        = vault_auth_backend.approle.path
  role_name      = "nats-route-${each.key}"
  token_policies = [vault_policy.nats_route_signer[each.key].name]

  bind_secret_id     = true
  secret_id_ttl      = 0
  secret_id_num_uses = 0

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
