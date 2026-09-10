data "authentik_stage" "default_authentication_mfa_validation" {
  name = "default-authentication-mfa-validation"
}

resource "authentik_stage_identification" "default_authentication" {
  name                      = "default-authentication-identification"
  user_fields               = ["email", "username"]
  case_insensitive_matching = true
  show_matched_user         = true
  pretend_user_exists       = true
  show_source_labels        = false
  enable_remember_me        = false
  sources                   = []
  webauthn_stage            = data.authentik_stage.default_authentication_mfa_validation.id
  passwordless_flow         = authentik_flow.passkey_login.uuid
}

resource "authentik_flow" "passkey_login" {
  name        = "Jorthaus passkey login"
  title       = "Sign in with a passkey"
  slug        = "jorthaus-passkey-login"
  designation = "authentication"
}

resource "authentik_stage_authenticator_validate" "passkey_login" {
  name                  = "jorthaus-passkey-login-validation"
  not_configured_action = "deny"
  device_classes        = ["webauthn"]
}

resource "authentik_stage_user_login" "passkey_login" {
  name = "jorthaus-passkey-login-complete"
}

resource "authentik_flow_stage_binding" "passkey_login_validation" {
  target = authentik_flow.passkey_login.uuid
  stage  = authentik_stage_authenticator_validate.passkey_login.id
  order  = 10
}

resource "authentik_flow_stage_binding" "passkey_login_complete" {
  target = authentik_flow.passkey_login.uuid
  stage  = authentik_stage_user_login.passkey_login.id
  order  = 100
}

import {
  to = authentik_stage_identification.default_authentication
  id = "8d233520-63a4-4923-af82-76158b9f48f8"
}
