resource "authentik_provider_proxy" "victorialogs" {
  name                  = "VictoriaLogs"
  external_host         = "https://logs.jort.haus"
  mode                  = "forward_single"
  access_token_validity = "hours=8"
  authorization_flow    = data.authentik_flow.provider_authorization.id
  invalidation_flow     = data.authentik_flow.provider_invalidation.id
}

resource "authentik_application" "victorialogs" {
  name              = "VictoriaLogs"
  slug              = "victorialogs"
  protocol_provider = authentik_provider_proxy.victorialogs.id
}

resource "authentik_policy_binding" "victorialogs_admins" {
  target = authentik_application.victorialogs.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 0
}
