resource "authentik_provider_proxy" "sonarr" {
  name                  = "Sonarr"
  external_host         = "https://sonarr.jort.haus"
  mode                  = "forward_single"
  access_token_validity = "hours=8"
  authorization_flow    = data.authentik_flow.provider_authorization.id
  invalidation_flow     = data.authentik_flow.provider_invalidation.id
}

resource "authentik_application" "sonarr" {
  name              = "Sonarr"
  slug              = "sonarr"
  protocol_provider = authentik_provider_proxy.sonarr.id
}

resource "authentik_policy_binding" "sonarr_admins" {
  target = authentik_application.sonarr.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 0
}

resource "authentik_provider_proxy" "radarr" {
  name                  = "Radarr"
  external_host         = "https://radarr.jort.haus"
  mode                  = "forward_single"
  access_token_validity = "hours=8"
  authorization_flow    = data.authentik_flow.provider_authorization.id
  invalidation_flow     = data.authentik_flow.provider_invalidation.id
}

resource "authentik_application" "radarr" {
  name              = "Radarr"
  slug              = "radarr"
  protocol_provider = authentik_provider_proxy.radarr.id
}

resource "authentik_policy_binding" "radarr_admins" {
  target = authentik_application.radarr.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 0
}

resource "authentik_provider_proxy" "prowlarr" {
  name                  = "Prowlarr"
  external_host         = "https://prowlarr.jort.haus"
  mode                  = "forward_single"
  access_token_validity = "hours=8"
  authorization_flow    = data.authentik_flow.provider_authorization.id
  invalidation_flow     = data.authentik_flow.provider_invalidation.id
}

resource "authentik_application" "prowlarr" {
  name              = "Prowlarr"
  slug              = "prowlarr"
  protocol_provider = authentik_provider_proxy.prowlarr.id
}

resource "authentik_policy_binding" "prowlarr_admins" {
  target = authentik_application.prowlarr.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 0
}
