resource "vault_mount" "authentik" {
  path        = "authentik"
  type        = "kv"
  description = "Authentik configuration secrets"

  options = {
    version = "2"
  }
}

resource "vault_database_secret_backend_connection" "authentik" {
  backend           = vault_mount.postgres.path
  name              = "authentik"
  plugin_name       = "postgresql-database-plugin"
  allowed_roles     = ["authentik"]
  verify_connection = true

  postgresql {
    connection_url          = "postgresql://{{username}}:{{password}}@postgres.service.jort.haus:5432/authentik?sslmode=verify-full"
    username                = "postgres"
    password_wo             = var.postgres_admin_password
    password_wo_version     = 1
    max_open_connections    = 5
    max_connection_lifetime = 300
  }
}

resource "vault_database_secret_backend_role" "authentik_postgres" {
  backend = vault_mount.postgres.path
  name    = "authentik"
  db_name = vault_database_secret_backend_connection.authentik.name

  default_ttl = 1209600
  max_ttl     = 1814400

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT \"authentik\" TO \"{{name}}\";",
  ]

  revocation_statements = [
    "REASSIGN OWNED BY \"{{name}}\" TO \"authentik\";",
    "DROP OWNED BY \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";",
  ]
}

resource "random_password" "authentik_secret_key" {
  length  = 64
  special = true
}

resource "random_password" "authentik_bootstrap_password" {
  length  = 32
  special = true
}

resource "random_password" "authentik_bootstrap_token" {
  length  = 64
  special = false
}

resource "vault_kv_secret_v2" "authentik_config" {
  mount = vault_mount.authentik.path
  name  = "config"

  data_json = jsonencode({
    bootstrap_password   = random_password.authentik_bootstrap_password.result
    bootstrap_token      = random_password.authentik_bootstrap_token.result
    postgres_host        = "postgres.service.jort.haus"
    postgres_name        = "authentik"
    postgres_port        = "5432"
    postgres_sslmode     = "verify-full"
    postgres_sslrootcert = "system"
    secret_key           = random_password.authentik_secret_key.result
  })
}

resource "vault_policy" "authentik_csi" {
  name = "authentik-csi"

  policy = <<-EOT
    path "authentik/data/config" {
      capabilities = ["read"]
    }

    path "postgres/creds/authentik" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "authentik" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "authentik"
  bound_service_account_names      = ["authentik-secret-sync"]
  bound_service_account_namespaces = ["authentik"]
  audience                         = "vault"
  token_policies                   = [vault_policy.authentik_csi.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
