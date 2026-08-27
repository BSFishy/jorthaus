resource "vault_mount" "postgres" {
  path        = "postgres"
  type        = "database"
  description = "PostgreSQL database secrets engine"
}

resource "vault_database_secret_backend_connection" "postgres" {
  backend           = vault_mount.postgres.path
  name              = "postgres"
  plugin_name       = "postgresql-database-plugin"
  allowed_roles     = ["*"]
  verify_connection = true

  postgresql {
    connection_url          = "postgresql://{{username}}:{{password}}@postgres.service.jort.haus:5432/postgres?sslmode=verify-full"
    username                = "postgres"
    password_wo             = var.postgres_admin_password
    password_wo_version     = 1
    max_open_connections    = 5
    max_connection_lifetime = 300
  }
}

resource "vault_database_secret_backend_static_role" "seaweedfs" {
  backend         = vault_mount.postgres.path
  name            = "seaweedfs"
  db_name         = vault_database_secret_backend_connection.postgres.name
  username        = "seaweedfs"
  rotation_period = 2592000

  rotation_statements = [
    "ALTER ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}';"
  ]
}
