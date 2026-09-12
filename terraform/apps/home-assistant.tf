data "authentik_certificate_key_pair" "generated" {
  name              = "authentik Self-signed Certificate"
  fetch_certificate = false
  fetch_key         = false
}

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

resource "authentik_group" "jorthaus_hass" {
  name         = "jorthaus-hass"
  is_superuser = false
}

resource "authentik_property_mapping_provider_scope" "home_assistant_profile" {
  name        = "Home Assistant profile"
  scope_name  = "profile"
  description = "Provides the Home Assistant display name and username."
  expression  = <<-EOT
    return delete_none_values({
        "name": request.user.name,
        "preferred_username": request.user.username,
    })
  EOT
}

resource "authentik_property_mapping_provider_scope" "home_assistant_groups" {
  name        = "Home Assistant groups"
  scope_name  = "groups"
  description = "Provides Home Assistant role groups."
  expression  = <<-EOT
    return {
        "groups": [
            group.name for group in request.user.groups.all()
            if group.name in ["jorthaus-admins", "jorthaus-hass"]
        ],
    }
  EOT
}

resource "authentik_provider_oauth2" "home_assistant" {
  name               = "Home Assistant"
  client_id          = "home-assistant"
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.provider_authorization.id
  invalidation_flow  = data.authentik_flow.provider_invalidation.id
  issuer_mode        = "per_provider"
  signing_key        = data.authentik_certificate_key_pair.generated.id
  sub_mode           = "user_uuid"
  grant_types        = ["authorization_code", "refresh_token"]
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    authentik_property_mapping_provider_scope.home_assistant_profile.id,
    authentik_property_mapping_provider_scope.home_assistant_groups.id,
  ]

  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      redirect_uri_type = "authorization"
      url               = "https://home.jort.haus/auth/oidc/callback"
    },
  ]
}

resource "authentik_application" "home_assistant" {
  name              = "Home Assistant"
  slug              = "home-assistant"
  protocol_provider = authentik_provider_oauth2.home_assistant.id
}

resource "authentik_policy_binding" "home_assistant_hass" {
  target = authentik_application.home_assistant.uuid
  group  = authentik_group.jorthaus_hass.id
  order  = 0
}

resource "authentik_policy_binding" "home_assistant_admins" {
  target = authentik_application.home_assistant.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 1
}

resource "vault_kv_secret_v2" "home_assistant_oidc" {
  mount = "authentik"
  name  = "home-assistant-oidc"

  data_json_wo = jsonencode({
    client_id     = authentik_provider_oauth2.home_assistant.client_id
    client_secret = authentik_provider_oauth2.home_assistant.client_secret
    discovery_url = "https://auth.jort.haus/application/o/home-assistant/.well-known/openid-configuration"
  })
  data_json_wo_version = 1
}
