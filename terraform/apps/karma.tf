resource "authentik_provider_proxy" "karma" {
  name                  = "Karma"
  external_host         = "https://alerts.jort.haus"
  mode                  = "forward_single"
  access_token_validity = "hours=8"
  authorization_flow    = data.authentik_flow.provider_authorization.id
  invalidation_flow     = data.authentik_flow.provider_invalidation.id
}

resource "authentik_application" "karma" {
  name              = "Karma"
  slug              = "karma"
  protocol_provider = authentik_provider_proxy.karma.id
}

resource "authentik_policy_binding" "karma_admins" {
  target = authentik_application.karma.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 0
}
