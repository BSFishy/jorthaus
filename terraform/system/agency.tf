resource "vault_mount" "agency" {
  path        = "agency"
  type        = "kv"
  description = "Agency application secrets"

  options = {
    version = "2"
  }
}

resource "vault_policy" "agency_image_pull" {
  name = "agency-image-pull"

  policy = <<-EOT
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }

    path "${vault_mount.agency.path}/data/image-pull" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "agency_image_pull" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "agency-image-pull"
  bound_service_account_names      = ["agency-external-secrets"]
  bound_service_account_namespaces = ["agency"]
  audience                         = "vault"
  token_policies                   = [vault_policy.agency_image_pull.name]

  token_no_default_policy = true
  token_type              = "service"
  token_ttl               = 3600
  token_max_ttl           = 3600
}

resource "vault_policy" "agency_forgejo_webhook" {
  name = "agency-forgejo-webhook"

  policy = <<-EOT
    path "${vault_mount.agency.path}/data/forgejo-webhook" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "agency_forgejo_webhook" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "agency-forgejo-webhook"
  bound_service_account_names      = ["agency"]
  bound_service_account_namespaces = ["agency"]
  audience                         = "vault"
  token_policies                   = [vault_policy.agency_forgejo_webhook.name]

  token_no_default_policy = true
  token_type              = "service"
  token_ttl               = 3600
  token_max_ttl           = 3600
}
