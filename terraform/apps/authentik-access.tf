data "authentik_group" "jorthaus_admins" {
  name          = "jorthaus-admins"
  include_users = false
}
