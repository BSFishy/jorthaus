resource "b2_bucket" "forgejo_volsync" {
  bucket_name = var.forgejo_volsync_bucket_name
  bucket_type = "allPrivate"

  lifecycle_rules {
    file_name_prefix = var.forgejo_volsync_restic_prefix

    days_from_starting_to_canceling_unfinished_large_files = 7
  }
}

resource "b2_application_key" "forgejo_volsync" {
  key_name = "jorthaus-forgejo-volsync"

  bucket_ids  = [b2_bucket.forgejo_volsync.bucket_id]
  name_prefix = var.forgejo_volsync_restic_prefix

  capabilities = [
    "deleteFiles",
    "listBuckets",
    "listFiles",
    "readFiles",
    "writeFiles",
  ]
}

resource "random_password" "forgejo_volsync_restic" {
  length  = 64
  special = true
}

resource "vault_kv_secret_v2" "forgejo_volsync" {
  mount = vault_mount.backup.path
  name  = "forgejo-volsync"

  data_json = jsonencode({
    aws_access_key_id     = b2_application_key.forgejo_volsync.application_key_id
    aws_secret_access_key = b2_application_key.forgejo_volsync.application_key
    aws_endpoint          = var.forgejo_volsync_s3_endpoint
    aws_region            = var.forgejo_volsync_aws_region
    bucket_name           = b2_bucket.forgejo_volsync.bucket_name
    restic_password       = random_password.forgejo_volsync_restic.result
    restic_repository     = "s3:${var.forgejo_volsync_s3_endpoint}/${b2_bucket.forgejo_volsync.bucket_name}/${trimsuffix(var.forgejo_volsync_restic_prefix, "/")}"
  })
}

resource "vault_policy" "forgejo_volsync" {
  name = "forgejo-volsync"

  policy = <<-EOT
    path "backup/data/forgejo-volsync" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "forgejo_volsync" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "forgejo-volsync"
  bound_service_account_names      = ["forgejo-volsync"]
  bound_service_account_namespaces = ["forgejo"]
  audience                         = "vault"
  token_policies                   = [vault_policy.forgejo_volsync.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}

resource "b2_bucket" "hister_volsync" {
  bucket_name = var.hister_volsync_bucket_name
  bucket_type = "allPrivate"

  lifecycle_rules {
    file_name_prefix = var.hister_volsync_restic_prefix

    days_from_starting_to_canceling_unfinished_large_files = 7
  }
}

resource "b2_application_key" "hister_volsync" {
  key_name = "jorthaus-hister-volsync"

  bucket_ids  = [b2_bucket.hister_volsync.bucket_id]
  name_prefix = var.hister_volsync_restic_prefix

  capabilities = [
    "deleteFiles",
    "listBuckets",
    "listFiles",
    "readFiles",
    "writeFiles",
  ]
}

resource "random_password" "hister_volsync_restic" {
  length  = 64
  special = true
}

resource "vault_kv_secret_v2" "hister_volsync" {
  mount = vault_mount.backup.path
  name  = "hister-volsync"

  data_json = jsonencode({
    aws_access_key_id     = b2_application_key.hister_volsync.application_key_id
    aws_secret_access_key = b2_application_key.hister_volsync.application_key
    aws_endpoint          = var.hister_volsync_s3_endpoint
    aws_region            = var.hister_volsync_aws_region
    bucket_name           = b2_bucket.hister_volsync.bucket_name
    restic_password       = random_password.hister_volsync_restic.result
    restic_repository     = "s3:${var.hister_volsync_s3_endpoint}/${b2_bucket.hister_volsync.bucket_name}/${trimsuffix(var.hister_volsync_restic_prefix, "/")}"
  })
}

resource "vault_policy" "hister_volsync" {
  name = "hister-volsync"

  policy = <<-EOT
    path "backup/data/hister-volsync" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "hister_volsync" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "hister-volsync"
  bound_service_account_names      = ["hister-volsync"]
  bound_service_account_namespaces = ["hister"]
  audience                         = "vault"
  token_policies                   = [vault_policy.hister_volsync.name]

  token_type    = "service"
  token_period  = 86400
  token_ttl     = 3600
  token_max_ttl = 14400
}
