locals {
  terraform_apps_permissions = toset([
    "authentik_core.add_application",
    "authentik_core.change_application",
    "authentik_core.change_user",
    "authentik_core.delete_application",
    "authentik_core.view_application",
    "authentik_core.view_group",
    "authentik_core.view_user",
    "authentik_flows.add_flow",
    "authentik_flows.add_flowstagebinding",
    "authentik_flows.change_flow",
    "authentik_flows.change_flowstagebinding",
    "authentik_flows.delete_flow",
    "authentik_flows.delete_flowstagebinding",
    "authentik_flows.view_flow",
    "authentik_flows.view_flowstagebinding",
    "authentik_flows.view_stage",
    "authentik_outposts.add_outpost",
    "authentik_outposts.change_outpost",
    "authentik_outposts.delete_outpost",
    "authentik_outposts.view_outpost",
    "authentik_policies.add_policybinding",
    "authentik_policies.change_policybinding",
    "authentik_policies.delete_policybinding",
    "authentik_policies.view_policybinding",
    "authentik_providers_proxy.add_proxyprovider",
    "authentik_providers_proxy.change_proxyprovider",
    "authentik_providers_proxy.delete_proxyprovider",
    "authentik_providers_proxy.view_proxyprovider",
    "authentik_stages_authenticator_validate.add_authenticatorvalidatestage",
    "authentik_stages_authenticator_validate.change_authenticatorvalidatestage",
    "authentik_stages_authenticator_validate.delete_authenticatorvalidatestage",
    "authentik_stages_authenticator_validate.view_authenticatorvalidatestage",
    "authentik_stages_identification.add_identificationstage",
    "authentik_stages_identification.change_identificationstage",
    "authentik_stages_identification.delete_identificationstage",
    "authentik_stages_identification.view_identificationstage",
    "authentik_stages_user_login.add_userloginstage",
    "authentik_stages_user_login.change_userloginstage",
    "authentik_stages_user_login.delete_userloginstage",
    "authentik_stages_user_login.view_userloginstage",
  ])
}

resource "authentik_rbac_role" "terraform_apps" {
  name = "jorthaus-terraform-apps"
}

resource "authentik_rbac_permission_role" "terraform_apps" {
  for_each = local.terraform_apps_permissions

  role       = authentik_rbac_role.terraform_apps.id
  permission = each.value
}

data "authentik_group" "terraform" {
  name          = "terraform"
  include_users = false
}

resource "authentik_user" "terraform" {
  username  = "terraform"
  name      = "terraform"
  type      = "service_account"
  is_active = true
  email     = ""
  path      = "goauthentik.io/service-accounts"
  groups    = [data.authentik_group.terraform.id]
  roles     = [authentik_rbac_role.terraform_apps.id]
  attributes = jsonencode({
    "goauthentik.io/user/token-expires" = true
  })

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = authentik_rbac_role.terraform_apps
  id = "58109253-db31-4f92-9d70-3a5843857341"
}

import {
  to = authentik_user.terraform
  id = "36"
}
