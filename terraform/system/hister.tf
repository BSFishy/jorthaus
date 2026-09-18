resource "vault_database_secret_backend_connection" "hister" {
  backend           = vault_mount.postgres.path
  name              = "hister"
  plugin_name       = "postgresql-database-plugin"
  allowed_roles     = ["hister-static"]
  verify_connection = true

  postgresql {
    connection_url          = "postgresql://{{username}}:{{password}}@postgres.service.jort.haus:5432/hister?sslmode=verify-full"
    username                = "postgres"
    password_wo             = var.postgres_admin_password
    password_wo_version     = 1
    max_open_connections    = 5
    max_connection_lifetime = 300
  }
}

resource "vault_database_secret_backend_static_role" "hister" {
  backend         = vault_mount.postgres.path
  name            = "hister-static"
  db_name         = vault_database_secret_backend_connection.hister.name
  username        = "hister_app"
  rotation_period = 15552000

  rotation_statements = [
    "ALTER ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' CONNECTION LIMIT 5;"
  ]
}

resource "vault_policy" "hister_csi" {
  name = "hister-csi"

  policy = <<-EOT
    path "authentik/data/hister-oidc" {
      capabilities = ["read"]
    }

    path "postgres/static-creds/hister-static" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "hister" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "hister"
  bound_service_account_names      = ["hister"]
  bound_service_account_namespaces = ["hister"]
  audience                         = "vault"
  token_policies                   = [vault_policy.hister_csi.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
