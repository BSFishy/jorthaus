resource "b2_bucket" "minecraft_backups" {
  bucket_name = var.minecraft_backup_bucket_name
  bucket_type = "allPrivate"

  lifecycle_rules {
    file_name_prefix = var.minecraft_backup_restic_prefix

    days_from_starting_to_canceling_unfinished_large_files = 7
  }
}

resource "b2_application_key" "minecraft_backups" {
  key_name = "jorthaus-minecraft-backups"

  bucket_ids  = [b2_bucket.minecraft_backups.bucket_id]
  name_prefix = var.minecraft_backup_restic_prefix

  capabilities = [
    "deleteFiles",
    "listBuckets",
    "listFiles",
    "readFiles",
    "writeFiles",
  ]
}

resource "random_password" "minecraft_backup_restic" {
  length  = 64
  special = true
}

resource "vault_generic_secret" "minecraft_backup" {
  path = "${vault_mount.backup.path}/data/minecraft"

  data_json = jsonencode({
    data = {
      aws_access_key_id     = b2_application_key.minecraft_backups.application_key_id
      aws_secret_access_key = b2_application_key.minecraft_backups.application_key
      aws_endpoint          = var.minecraft_backup_s3_endpoint
      aws_region            = var.minecraft_backup_aws_region
      bucket_name           = b2_bucket.minecraft_backups.bucket_name
      restic_password       = random_password.minecraft_backup_restic.result
      restic_repository     = "s3:${var.minecraft_backup_s3_endpoint}/${b2_bucket.minecraft_backups.bucket_name}/${trimsuffix(var.minecraft_backup_restic_prefix, "/")}"
    }
  })
}
