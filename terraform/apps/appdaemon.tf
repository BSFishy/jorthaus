resource "authentik_provider_proxy" "appdaemon" {
  name               = "AppDaemon"
  external_host      = "https://appdaemon.jort.haus"
  mode               = "forward_single"
  authorization_flow = data.authentik_flow.provider_authorization.id
  invalidation_flow  = data.authentik_flow.provider_invalidation.id
}

resource "authentik_application" "appdaemon" {
  name              = "AppDaemon"
  slug              = "appdaemon"
  protocol_provider = authentik_provider_proxy.appdaemon.id
}

resource "authentik_policy_binding" "appdaemon_admins" {
  target = authentik_application.appdaemon.uuid
  group  = data.authentik_group.jorthaus_admins.id
  order  = 0
}
