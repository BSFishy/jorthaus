resource "vault_mount" "cloudflare" {
  path        = "cloudflare"
  type        = "kv"
  description = "Cloudflare API credentials for cluster services"

  options = {
    version = "2"
  }
}

resource "vault_kv_secret_v2" "cloudflare_api_token" {
  mount = vault_mount.cloudflare.path
  name  = "api-token"

  data_json = jsonencode({
    api_token = var.cloudflare_api_token
  })
}

resource "vault_policy" "cert_manager_cloudflare_csi" {
  name = "cert-manager-cloudflare-csi"

  policy = <<-EOT
    path "cloudflare/data/api-token" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "cert_manager_cloudflare" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "cert-manager-cloudflare"
  bound_service_account_names      = ["cert-manager-cloudflare-sync"]
  bound_service_account_namespaces = ["cert-manager"]
  audience                         = "vault"
  token_policies                   = [vault_policy.cert_manager_cloudflare_csi.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
