resource "vault_mount" "forgejo" {
  path        = "forgejo"
  type        = "kv"
  description = "Forgejo runtime and recovery secrets"

  options = {
    version = "2"
  }
}

resource "vault_database_secret_backend_connection" "forgejo" {
  backend           = vault_mount.postgres.path
  name              = "forgejo"
  plugin_name       = "postgresql-database-plugin"
  allowed_roles     = ["forgejo-static"]
  verify_connection = true

  postgresql {
    connection_url          = "postgresql://{{username}}:{{password}}@postgres.service.jort.haus:5432/forgejo?sslmode=verify-full"
    username                = "postgres"
    password_wo             = var.postgres_admin_password
    password_wo_version     = 1
    max_open_connections    = 5
    max_connection_lifetime = 300
  }
}

resource "vault_database_secret_backend_static_role" "forgejo" {
  backend         = vault_mount.postgres.path
  name            = "forgejo-static"
  db_name         = vault_database_secret_backend_connection.forgejo.name
  username        = "forgejo_app"
  rotation_period = 15552000

  rotation_statements = [
    "ALTER ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' CONNECTION LIMIT 5;"
  ]
}

resource "random_password" "forgejo_secret_key" {
  length  = 64
  special = true
}

resource "random_password" "forgejo_internal_token" {
  length  = 64
  special = true
}

resource "random_password" "forgejo_lfs_jwt_secret" {
  length  = 64
  special = true
}

resource "random_password" "forgejo_recovery_password" {
  length  = 64
  special = true
}

resource "vault_kv_secret_v2" "forgejo_config" {
  mount = vault_mount.forgejo.path
  name  = "config"

  data_json = jsonencode({
    internal_token = random_password.forgejo_internal_token.result
    lfs_jwt_secret = random_password.forgejo_lfs_jwt_secret.result
    secret_key     = random_password.forgejo_secret_key.result
  })
}

resource "vault_kv_secret_v2" "forgejo_bootstrap" {
  mount = vault_mount.forgejo.path
  name  = "bootstrap"

  data_json = jsonencode({
    username = "forgejo-recovery"
    password = random_password.forgejo_recovery_password.result
  })
}

resource "vault_policy" "forgejo_csi" {
  name = "forgejo-csi"

  policy = <<-EOT
    path "forgejo/data/bootstrap" {
      capabilities = ["read"]
    }

    path "forgejo/data/config" {
      capabilities = ["read"]
    }

    path "authentik/data/forgejo-oidc" {
      capabilities = ["read"]
    }

    path "postgres/static-creds/forgejo-static" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "forgejo" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "forgejo"
  bound_service_account_names      = ["forgejo"]
  bound_service_account_namespaces = ["forgejo"]
  audience                         = "vault"
  token_policies                   = [vault_policy.forgejo_csi.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
