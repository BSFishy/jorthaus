resource "vault_mount" "valkey" {
  path        = "valkey"
  type        = "database"
  description = "Valkey database secrets engine"
}

resource "vault_database_secret_backend_connection" "valkey" {
  backend           = vault_mount.valkey.path
  name              = "valkey"
  plugin_name       = "redis-database-plugin"
  allowed_roles     = ["*"]
  verify_connection = true

  redis {
    host     = "valkey.service.jort.haus"
    port     = 6379
    username = "default"
    password = var.valkey_admin_password
    tls      = true
    ca_cert  = file("/etc/ssl/certs/ca-certificates.crt")
  }
}
