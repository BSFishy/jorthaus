resource "authentik_group" "jorthaus_hister" {
  name         = "jorthaus-hister"
  is_superuser = false
}

resource "authentik_property_mapping_provider_scope" "hister_profile" {
  name        = "Hister profile"
  scope_name  = "profile"
  description = "Provides the Hister display name and username."
  expression  = <<-EOT
    return delete_none_values({
        "name": request.user.name,
        "preferred_username": request.user.username,
    })
  EOT
}

resource "authentik_property_mapping_provider_scope" "hister_email" {
  name        = "Hister email"
  scope_name  = "email"
  description = "Provides the Hister account email address."
  expression  = <<-EOT
    return delete_none_values({
        "email": request.user.email,
    })
  EOT
}

resource "authentik_provider_oauth2" "hister" {
  name               = "Hister"
  client_id          = "hister"
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.provider_authorization.id
  invalidation_flow  = data.authentik_flow.provider_invalidation.id
  issuer_mode        = "per_provider"
  signing_key        = data.authentik_certificate_key_pair.generated.id
  sub_mode           = "user_uuid"
  grant_types        = ["authorization_code", "refresh_token"]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    authentik_property_mapping_provider_scope.hister_profile.id,
    authentik_property_mapping_provider_scope.hister_email.id,
  ]

  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      redirect_uri_type = "authorization"
      url               = "https://hister.jort.haus/api/oauth/callback?provider=oidc"
    },
  ]
}

resource "authentik_application" "hister" {
  name              = "Hister"
  slug              = "hister"
  protocol_provider = authentik_provider_oauth2.hister.id
}

resource "authentik_policy_binding" "hister_access" {
  target = authentik_application.hister.uuid
  group  = authentik_group.jorthaus_hister.id
  order  = 0
}

resource "authentik_policy_binding" "hister_admins" {
  target = authentik_application.hister.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 1
}

resource "vault_kv_secret_v2" "hister_oidc" {
  mount = "authentik"
  name  = "hister-oidc"

  data_json_wo = jsonencode({
    client_id     = authentik_provider_oauth2.hister.client_id
    client_secret = authentik_provider_oauth2.hister.client_secret
    discovery_url = "https://auth.jort.haus/application/o/hister/.well-known/openid-configuration"
  })
  data_json_wo_version = 1
}
