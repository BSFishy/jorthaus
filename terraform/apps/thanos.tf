resource "authentik_provider_proxy" "thanos" {
  name                  = "Thanos"
  external_host         = "https://metrics.jort.haus"
  mode                  = "forward_single"
  access_token_validity = "hours=8"
  authorization_flow    = data.authentik_flow.provider_authorization.id
  invalidation_flow     = data.authentik_flow.provider_invalidation.id
}

resource "authentik_application" "thanos" {
  name              = "Thanos"
  slug              = "thanos"
  protocol_provider = authentik_provider_proxy.thanos.id
}

resource "authentik_policy_binding" "thanos_admins" {
  target = authentik_application.thanos.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 0
}
