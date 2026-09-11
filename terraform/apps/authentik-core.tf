data "authentik_flow" "provider_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "provider_invalidation" {
  slug = "default-provider-invalidation-flow"
}

locals {
  embedded_proxy_provider_ids = [
    authentik_provider_proxy.traefik_dashboard.id,
  ]
}

resource "authentik_outpost" "embedded" {
  name               = "authentik Embedded Outpost"
  type               = "proxy"
  protocol_providers = local.embedded_proxy_provider_ids
}

import {
  to = authentik_outpost.embedded
  id = "7be213d8-3197-4399-bf18-d625a0da681d"
}
