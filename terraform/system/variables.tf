variable "postgres_admin_password" {
  type        = string
  description = "Administrative PostgreSQL password used by OpenBao for the database connection. Set this with TF_VAR_postgres_admin_password."
  sensitive   = true
}
