resource "authentik_group" "jorthaus_forgejo" {
  name         = "jorthaus-forgejo"
  is_superuser = false
}

resource "authentik_property_mapping_provider_scope" "forgejo_profile" {
  name        = "Forgejo profile"
  scope_name  = "profile"
  description = "Provides the Forgejo display name and username."
  expression  = <<-EOT
    return delete_none_values({
        "name": request.user.name,
        "preferred_username": request.user.username,
    })
  EOT
}

resource "authentik_property_mapping_provider_scope" "forgejo_email" {
  name        = "Forgejo email"
  scope_name  = "email"
  description = "Provides the Forgejo account email address."
  expression  = <<-EOT
    return delete_none_values({
        "email": request.user.email,
    })
  EOT
}

resource "authentik_property_mapping_provider_scope" "forgejo_groups" {
  name        = "Forgejo groups"
  scope_name  = "groups"
  description = "Provides the Forgejo access and administrator groups."
  expression  = <<-EOT
    return {
        "groups": [
            group.name for group in request.user.groups.all()
            if group.name in ["jorthaus-admins", "jorthaus-forgejo"]
        ],
    }
  EOT
}

resource "authentik_provider_oauth2" "forgejo" {
  name               = "Forgejo"
  client_id          = "forgejo"
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.provider_authorization.id
  invalidation_flow  = data.authentik_flow.provider_invalidation.id
  issuer_mode        = "per_provider"
  signing_key        = data.authentik_certificate_key_pair.generated.id
  sub_mode           = "user_uuid"
  grant_types        = ["authorization_code", "refresh_token"]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    authentik_property_mapping_provider_scope.forgejo_profile.id,
    authentik_property_mapping_provider_scope.forgejo_email.id,
    authentik_property_mapping_provider_scope.forgejo_groups.id,
  ]

  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      redirect_uri_type = "authorization"
      url               = "https://git.jort.haus/user/oauth2/authentik/callback"
    },
  ]
}

resource "authentik_application" "forgejo" {
  name              = "Forgejo"
  slug              = "forgejo"
  protocol_provider = authentik_provider_oauth2.forgejo.id
}

resource "authentik_policy_binding" "forgejo_access" {
  target = authentik_application.forgejo.uuid
  group  = authentik_group.jorthaus_forgejo.id
  order  = 0
}

resource "authentik_policy_binding" "forgejo_admins" {
  target = authentik_application.forgejo.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 1
}

resource "vault_kv_secret_v2" "forgejo_oidc" {
  mount = "authentik"
  name  = "forgejo-oidc"

  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.forgejo.client_id
    client_secret = authentik_provider_oauth2.forgejo.client_secret
    discovery_url = "https://auth.jort.haus/application/o/forgejo/.well-known/openid-configuration"
  })
}
