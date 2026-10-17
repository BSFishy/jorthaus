resource "vault_database_secret_backend_connection" "oneuptime" {
  backend           = vault_mount.postgres.path
  name              = "oneuptime"
  plugin_name       = "postgresql-database-plugin"
  allowed_roles     = ["oneuptime"]
  verify_connection = true

  postgresql {
    connection_url          = "postgresql://{{username}}:{{password}}@postgres.service.jort.haus:5432/oneuptime?sslmode=verify-full"
    username                = "postgres"
    password_wo             = var.postgres_admin_password
    password_wo_version     = 1
    max_open_connections    = 5
    max_connection_lifetime = 300
  }
}

resource "vault_database_secret_backend_role" "oneuptime_valkey" {
  backend = vault_mount.valkey.path
  name    = "oneuptime"
  db_name = vault_database_secret_backend_connection.valkey.name

  creation_statements = [
    jsonencode([
      "resetdbs",
      "db=1",
      "~*",
      "&*",
      "+@read",
      "+@write",
      "+@connection",
      "+@pubsub",
      "+@scripting",
      "+@transaction",
      "+@blocking",
      "-@admin",
      "-@dangerous",
      "+info",
    ])
  ]

  default_ttl = 1209600
  max_ttl     = 1209600
}

resource "vault_database_secret_backend_role" "oneuptime_postgres" {
  backend = vault_mount.postgres.path
  name    = "oneuptime"
  db_name = vault_database_secret_backend_connection.oneuptime.name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}';",
    "GRANT oneuptime TO \"{{name}}\";",
    "ALTER ROLE \"{{name}}\" SET role TO 'oneuptime';"
  ]

  revocation_statements = [
    "REVOKE oneuptime FROM \"{{name}}\";",
    "DROP OWNED BY \"{{name}}\";",
    "DROP ROLE \"{{name}}\";"
  ]

  default_ttl = 1209600
  max_ttl     = 1209600
}

resource "random_password" "oneuptime_secret" {
  length  = 64
  special = false
}

resource "random_password" "oneuptime_encryption_secret" {
  length  = 64
  special = false
}

resource "random_password" "oneuptime_register_probe_key" {
  length  = 64
  special = false
}

resource "random_password" "oneuptime_probe_one_key" {
  length  = 64
  special = false
}

resource "vault_mount" "oneuptime" {
  path        = "oneuptime"
  type        = "kv"
  description = "OneUptime application secrets"

  options = {
    version = "2"
  }
}

resource "vault_kv_secret_v2" "oneuptime_config" {
  mount = vault_mount.oneuptime.path
  name  = "config"

  data_json = jsonencode({
    oneuptime_secret   = random_password.oneuptime_secret.result
    encryption_secret  = random_password.oneuptime_encryption_secret.result
    register_probe_key = random_password.oneuptime_register_probe_key.result
    probe_one_key      = random_password.oneuptime_probe_one_key.result
  })
}

resource "vault_policy" "oneuptime_csi" {
  name = "oneuptime-csi"

  policy = <<-EOT
    path "oneuptime/data/config" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "oneuptime_csi" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "oneuptime-csi"
  bound_service_account_names      = ["oneuptime-csi"]
  bound_service_account_namespaces = ["oneuptime"]
  audience                         = "vault"
  token_policies                   = [vault_policy.oneuptime_csi.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}

resource "vault_policy" "oneuptime_credential_sync" {
  name = "oneuptime-credential-sync"

  policy = <<-EOT
    path "postgres/creds/oneuptime" {
      capabilities = ["read"]
    }

    path "valkey/creds/oneuptime" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "oneuptime_credential_sync" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "oneuptime-credential-sync"
  bound_service_account_names      = ["oneuptime-credential-sync"]
  bound_service_account_namespaces = ["oneuptime"]
  audience                         = "vault"
  token_policies                   = [vault_policy.oneuptime_credential_sync.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
