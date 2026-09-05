variable "postgres_admin_password" {
  type        = string
  description = "Administrative PostgreSQL password used by OpenBao for the database connection. Set this with TF_VAR_postgres_admin_password."
  sensitive   = true
}

variable "valkey_admin_password" {
  type        = string
  description = "Administrative Valkey password used by OpenBao for the database connection. Set this with TF_VAR_valkey_admin_password."
  sensitive   = true
}

variable "minecraft_backup_bucket_name" {
  type        = string
  description = "Globally unique Backblaze B2 bucket name for Minecraft restic backups."
  default     = "jorthaus-minecraft-backups"
}

variable "minecraft_backup_s3_endpoint" {
  type        = string
  description = "S3-compatible Backblaze B2 endpoint used by restic for Minecraft backups."
  default     = "https://s3.us-east-005.backblazeb2.com"
}

variable "minecraft_backup_aws_region" {
  type        = string
  description = "AWS region value to expose to S3-compatible clients for the Minecraft backup bucket."
  default     = "us-east-005"
}

variable "minecraft_backup_restic_prefix" {
  type        = string
  description = "Object key prefix inside the Minecraft backup bucket for the restic repository."
  default     = "restic/vanilla/"
}
