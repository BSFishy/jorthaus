resource "vault_mount" "home_assistant" {
  path        = "home-assistant"
  type        = "kv"
  description = "Home Assistant application credentials"

  options = {
    version = "2"
  }
}

resource "vault_policy" "appdaemon_csi" {
  name = "appdaemon-csi"

  policy = <<-EOT
    path "home-assistant/data/appdaemon" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "appdaemon" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "appdaemon"
  bound_service_account_names      = ["appdaemon"]
  bound_service_account_namespaces = ["home-assistant"]
  audience                         = "vault"
  token_policies                   = [vault_policy.appdaemon_csi.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
