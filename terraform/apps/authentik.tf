data "authentik_user" "matt" {
  username = "matt"
}

resource "authentik_group" "jorthaus_admins" {
  name         = "jorthaus-admins"
  is_superuser = true
  users        = [data.authentik_user.matt.id]
}
