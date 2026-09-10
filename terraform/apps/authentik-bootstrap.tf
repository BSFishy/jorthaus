resource "authentik_user" "bootstrap_admin" {
  username   = "akadmin"
  name       = "authentik Default Admin"
  email      = "root@example.com"
  type       = "internal"
  path       = "users"
  is_active  = false
  groups     = ["deb45b96-0532-46b5-bcfa-3a4f6a817399"]
  roles      = []
  attributes = jsonencode({})
}

import {
  to = authentik_user.bootstrap_admin
  id = "4"
}
