variable "minecraft_public_hostname" {
  type        = string
  default     = "mc"
  description = "Public hostname label for Minecraft."
}

variable "minecraft_velocity_load_balancer_ip" {
  type        = string
  default     = "10.1.12.10"
  description = "Kubernetes LoadBalancer IP for the Minecraft Velocity service."
}

variable "cloudflare_ddns_login" {
  type        = string
  default     = null
  description = "Cloudflare login for UniFi dynamic DNS."
}

variable "cloudflare_ddns_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Cloudflare API credential for UniFi dynamic DNS."
}

resource "unifi_dynamic_dns" "minecraft_public" {
  count = var.cloudflare_ddns_login != null && var.cloudflare_ddns_password != null ? 1 : 0

  site      = var.site
  service   = "cloudflare"
  interface = "wan"
  host_name = "${var.minecraft_public_hostname}.${var.dns_domain}"
  login     = var.cloudflare_ddns_login
  password  = var.cloudflare_ddns_password
}

resource "unifi_port_forward" "minecraft_velocity" {
  site     = var.site
  name     = "Minecraft Velocity"
  protocol = "tcp"

  wan = {
    interface  = "wan"
    ip_address = "any"
    port       = "25565"
  }

  forward = {
    ip   = var.minecraft_velocity_load_balancer_ip
    port = "25565"
  }
}
