resource "authentik_provider_proxy" "traefik_dashboard" {
  name               = "Traefik dashboard"
  external_host      = "https://traefik.jort.haus"
  mode               = "forward_single"
  authorization_flow = data.authentik_flow.provider_authorization.id
  invalidation_flow  = data.authentik_flow.provider_invalidation.id
}

resource "authentik_application" "traefik_dashboard" {
  name              = "Traefik dashboard"
  slug              = "traefik-dashboard"
  protocol_provider = authentik_provider_proxy.traefik_dashboard.id
}

resource "authentik_policy_binding" "traefik_dashboard_admins" {
  target = authentik_application.traefik_dashboard.uuid
  group  = authentik_group.jorthaus_admins.id
  order  = 0
}
