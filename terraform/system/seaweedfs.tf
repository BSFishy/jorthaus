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

resource "vault_mount" "seaweedfs_pki" {
  path                      = "seaweedfs-pki"
  type                      = "pki"
  description               = "SeaweedFS internal PKI"
  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = 315360000
}

resource "vault_pki_secret_backend_root_cert" "seaweedfs_pki" {
  backend     = vault_mount.seaweedfs_pki.path
  type        = "internal"
  common_name = "jorthaus SeaweedFS Internal CA"
  ttl         = "87600h"
  key_type    = "ec"
  key_bits    = 256
}

resource "vault_pki_secret_backend_role" "seaweedfs_node" {
  backend            = vault_mount.seaweedfs_pki.path
  name               = "seaweedfs-node"
  ttl                = "2592000"
  max_ttl            = "5184000"
  allow_bare_domains = true
  allow_subdomains   = true
  allow_glob_domains = true
  allowed_domains = [
    "node.jort.haus",
    "seaweed-master.service.jort.haus",
    "seaweed-filer.service.jort.haus",
  ]
  server_flag       = true
  client_flag       = true
  key_type          = "ec"
  key_bits          = 256
  require_cn        = true
  enforce_hostnames = false
}

data "vault_kv_secret_v2" "seaweedfs_security" {
  mount = vault_mount.seaweedfs.path
  name  = "security"
}

resource "vault_generic_secret" "seaweedfs_csi" {
  path = "${vault_mount.seaweedfs.path}/data/csi"

  data_json = jsonencode({
    data = {
      security_toml = <<-EOT
        [jwt.signing]
        key = "${data.vault_kv_secret_v2.seaweedfs_security.data["jwt_signing_key"]}"
        expires_after_seconds = 10

        [jwt.signing.read]
        key = "${data.vault_kv_secret_v2.seaweedfs_security.data["jwt_signing_read_key"]}"
        expires_after_seconds = 60

        [jwt.filer_signing]
        key = "${data.vault_kv_secret_v2.seaweedfs_security.data["jwt_filer_signing_key"]}"
        expires_after_seconds = 10

        [jwt.filer_signing.read]
        key = "${data.vault_kv_secret_v2.seaweedfs_security.data["jwt_filer_signing_read_key"]}"
        expires_after_seconds = 60

        [grpc]
        ca = "/var/run/secrets/app/tls/ca.crt"

        [grpc.client]
        cert = "/var/run/secrets/app/tls/tls.crt"
        key = "/var/run/secrets/app/tls/tls.key"
        ca = "/var/run/secrets/app/tls/ca.crt"

        [https.client]
        enabled = true
        ca = "/var/run/secrets/app/tls/ca.crt"
      EOT
    }
  })
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

    path "seaweedfs/data/security" {
      capabilities = ["read"]
    }

    path "seaweedfs-pki/issue/seaweedfs-node" {
      capabilities = ["update"]
    }

    path "seaweedfs-pki/cert/ca" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "seaweedfs_csi" {
  name = "seaweedfs-csi"

  policy = <<-EOT
    path "seaweedfs/data/csi" {
      capabilities = ["read"]
    }

    path "seaweedfs-pki/issue/seaweedfs-node" {
      capabilities = ["update"]
    }

    path "seaweedfs-pki/cert/ca" {
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

resource "vault_kubernetes_auth_backend_role" "seaweedfs_csi" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "seaweedfs-csi"
  bound_service_account_names      = ["seaweedfs-csi-config-sync"]
  bound_service_account_namespaces = ["kube-system"]
  audience                         = "vault"
  token_policies                   = [vault_policy.seaweedfs_csi.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
