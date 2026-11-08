resource "vault_database_secret_backend_connection" "agency" {
  backend           = vault_mount.postgres.path
  name              = "agency"
  plugin_name       = "postgresql-database-plugin"
  allowed_roles     = ["agency"]
  verify_connection = true

  postgresql {
    connection_url          = "postgresql://{{username}}:{{password}}@postgres.service.jort.haus:5432/agency?sslmode=verify-full"
    username                = "postgres"
    password_wo             = var.postgres_admin_password
    password_wo_version     = 1
    max_open_connections    = 5
    max_connection_lifetime = 300
  }
}

resource "vault_database_secret_backend_role" "agency" {
  backend = vault_mount.postgres.path
  name    = "agency"
  db_name = vault_database_secret_backend_connection.agency.name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' CONNECTION LIMIT 5;",
    "GRANT agency TO \"{{name}}\";",
    "ALTER ROLE \"{{name}}\" SET role TO 'agency';"
  ]

  revocation_statements = [
    "REVOKE agency FROM \"{{name}}\";",
    "DROP OWNED BY \"{{name}}\";",
    "DROP ROLE \"{{name}}\";"
  ]

  default_ttl = 3600
  max_ttl     = 3600
}

resource "vault_policy" "agency_postgres_credentials" {
  name = "agency-postgres-credentials"

  policy = <<-EOT
    path "${vault_mount.postgres.path}/creds/${vault_database_secret_backend_role.agency.name}" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "agency_postgres_credentials" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "agency-postgres-credentials"
  bound_service_account_names      = ["agency"]
  bound_service_account_namespaces = ["agency"]
  audience                         = "vault"
  token_policies                   = [vault_policy.agency_postgres_credentials.name]

  token_no_default_policy = true
  token_type              = "service"
  token_ttl               = 3600
  token_max_ttl           = 3600
}
