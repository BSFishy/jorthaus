variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API token synchronized to OpenBao for in-cluster DNS-01 consumers. The Just recipes set this from CLOUDFLARE_API_TOKEN."
  sensitive   = true
}

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

variable "home_assistant_backup_bucket_name" {
  type        = string
  description = "Globally unique Backblaze B2 bucket name for Home Assistant backups."
  default     = "jorthaus-home-assistant-backups"
}

variable "home_assistant_backup_s3_endpoint" {
  type        = string
  description = "S3-compatible Backblaze B2 endpoint used by Home Assistant backup clients."
  default     = "https://s3.us-east-005.backblazeb2.com"
}

variable "home_assistant_backup_aws_region" {
  type        = string
  description = "AWS region value to expose to S3-compatible Home Assistant backup clients."
  default     = "us-east-005"
}

variable "home_assistant_backup_prefix" {
  type        = string
  description = "Object-key prefix the Home Assistant backup key may access."
  default     = "home-assistant/"
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

variable "forgejo_volsync_bucket_name" {
  type        = string
  description = "Globally unique Backblaze B2 bucket name for Forgejo VolSync Restic backups."
  default     = "jorthaus-forgejo-volsync"
}

variable "forgejo_volsync_s3_endpoint" {
  type        = string
  description = "S3-compatible Backblaze B2 endpoint used by Forgejo VolSync Restic backups."
  default     = "https://s3.us-east-005.backblazeb2.com"
}

variable "forgejo_volsync_aws_region" {
  type        = string
  description = "AWS region value used by Forgejo VolSync Restic backups."
  default     = "us-east-005"
}

variable "forgejo_volsync_restic_prefix" {
  type        = string
  description = "Object key prefix inside the Forgejo VolSync bucket for its Restic repository."
  default     = "restic/forgejo/"
}

variable "hister_volsync_bucket_name" {
  type        = string
  description = "Globally unique Backblaze B2 bucket name for Hister VolSync Restic backups."
  default     = "jorthaus-hister-volsync"
}

variable "hister_volsync_s3_endpoint" {
  type        = string
  description = "S3-compatible Backblaze B2 endpoint used by Hister VolSync Restic backups."
  default     = "https://s3.us-east-005.backblazeb2.com"
}

variable "hister_volsync_aws_region" {
  type        = string
  description = "AWS region value used by Hister VolSync Restic backups."
  default     = "us-east-005"
}

variable "hister_volsync_restic_prefix" {
  type        = string
  description = "Object key prefix inside the Hister VolSync bucket for its Restic repository."
  default     = "restic/hister/"
}
