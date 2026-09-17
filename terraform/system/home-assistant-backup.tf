resource "b2_bucket" "home_assistant_backups" {
  bucket_name = var.home_assistant_backup_bucket_name
  bucket_type = "allPrivate"

  lifecycle_rules {
    file_name_prefix = var.home_assistant_backup_prefix

    days_from_starting_to_canceling_unfinished_large_files = 7
  }
}

resource "b2_application_key" "home_assistant_backups" {
  key_name = "jorthaus-home-assistant-backups-native"

  bucket_id   = b2_bucket.home_assistant_backups.bucket_id
  name_prefix = var.home_assistant_backup_prefix

  capabilities = [
    "deleteFiles",
    "listBuckets",
    "listFiles",
    "readFiles",
    "writeFiles",
  ]
}

resource "vault_kv_secret_v2" "home_assistant_backup" {
  mount = vault_mount.backup.path
  name  = "home-assistant"

  data_json = jsonencode({
    aws_access_key_id     = b2_application_key.home_assistant_backups.application_key_id
    aws_secret_access_key = b2_application_key.home_assistant_backups.application_key
    aws_endpoint          = var.home_assistant_backup_s3_endpoint
    aws_region            = var.home_assistant_backup_aws_region
    bucket_name           = b2_bucket.home_assistant_backups.bucket_name
    prefix                = var.home_assistant_backup_prefix
  })
}
