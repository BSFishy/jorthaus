resource "authentik_rbac_role" "invitation_issuer" {
  name = "jorthaus-invitation-issuer"
}

resource "authentik_rbac_permission_role" "invitation_issuer_create" {
  role       = authentik_rbac_role.invitation_issuer.id
  permission = "authentik_stages_invitation.add_invitation"
}

resource "authentik_user" "invitation_issuer" {
  username  = "invitation-issuer"
  name      = "Jorthaus invitation issuer"
  type      = "service_account"
  is_active = true
  email     = ""
  path      = "goauthentik.io/service-accounts"
  roles     = [authentik_rbac_role.invitation_issuer.id]
  attributes = jsonencode({
    "goauthentik.io/user/token-expires" = true
  })

  lifecycle {
    prevent_destroy = true
  }
}
