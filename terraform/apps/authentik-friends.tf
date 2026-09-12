resource "authentik_group" "jorthaus_friends" {
  name         = "jorthaus-friends"
  is_superuser = false
}

resource "authentik_flow" "friend_enrollment" {
  name           = "Jorthaus friend enrollment"
  title          = "Create your Jorthaus account"
  slug           = "jorthaus-friend-enrollment"
  designation    = "enrollment"
  authentication = "require_unauthenticated"
}

resource "authentik_stage_invitation" "friend_enrollment" {
  name                             = "jorthaus-friend-enrollment-invitation"
  continue_flow_without_invitation = false
}

resource "authentik_stage_prompt_field" "friend_username" {
  name        = "jorthaus-friend-enrollment-username"
  field_key   = "username"
  label       = "Username"
  type        = "username"
  required    = true
  placeholder = "Username"
  order       = 0
}

resource "authentik_stage_prompt_field" "friend_password" {
  name        = "jorthaus-friend-enrollment-password"
  field_key   = "password"
  label       = "Password"
  type        = "password"
  required    = true
  placeholder = "Password"
  order       = 1
}

resource "authentik_stage_prompt_field" "friend_password_repeat" {
  name        = "jorthaus-friend-enrollment-password-repeat"
  field_key   = "password_repeat"
  label       = "Password (repeat)"
  type        = "password"
  required    = true
  placeholder = "Password (repeat)"
  order       = 2
}

resource "authentik_stage_prompt_field" "friend_name" {
  name        = "jorthaus-friend-enrollment-name"
  field_key   = "name"
  label       = "Name"
  type        = "text"
  required    = true
  placeholder = "Name"
  order       = 0
}

resource "authentik_stage_prompt_field" "friend_email" {
  name        = "jorthaus-friend-enrollment-email"
  field_key   = "email"
  label       = "Email"
  type        = "email"
  required    = false
  placeholder = "Email (optional)"
  order       = 1
}

resource "authentik_stage_prompt" "friend_credentials" {
  name = "jorthaus-friend-enrollment-credentials"
  fields = [
    authentik_stage_prompt_field.friend_username.id,
    authentik_stage_prompt_field.friend_password.id,
    authentik_stage_prompt_field.friend_password_repeat.id,
  ]
}

resource "authentik_stage_prompt" "friend_details" {
  name = "jorthaus-friend-enrollment-details"
  fields = [
    authentik_stage_prompt_field.friend_name.id,
    authentik_stage_prompt_field.friend_email.id,
  ]
}

resource "authentik_stage_user_write" "friend_enrollment" {
  name                     = "jorthaus-friend-enrollment-user-write"
  create_users_as_inactive = false
  create_users_group       = authentik_group.jorthaus_friends.id
  user_creation_mode       = "always_create"
  user_path_template       = "users/friends"
  user_type                = "internal"
}

resource "authentik_stage_user_login" "friend_enrollment" {
  name = "jorthaus-friend-enrollment-login"
}

resource "authentik_flow_stage_binding" "friend_enrollment_invitation" {
  target               = authentik_flow.friend_enrollment.uuid
  stage                = authentik_stage_invitation.friend_enrollment.id
  order                = 5
  evaluate_on_plan     = true
  re_evaluate_policies = true
}

resource "authentik_flow_stage_binding" "friend_enrollment_credentials" {
  target = authentik_flow.friend_enrollment.uuid
  stage  = authentik_stage_prompt.friend_credentials.id
  order  = 10
}

resource "authentik_flow_stage_binding" "friend_enrollment_details" {
  target = authentik_flow.friend_enrollment.uuid
  stage  = authentik_stage_prompt.friend_details.id
  order  = 15
}

resource "authentik_flow_stage_binding" "friend_enrollment_user_write" {
  target = authentik_flow.friend_enrollment.uuid
  stage  = authentik_stage_user_write.friend_enrollment.id
  order  = 20
}

resource "authentik_flow_stage_binding" "friend_enrollment_login" {
  target = authentik_flow.friend_enrollment.uuid
  stage  = authentik_stage_user_login.friend_enrollment.id
  order  = 100
}
