variable "forgejo_ssh_public_hostname" {
  type        = string
  default     = "ssh.git"
  description = "Public DNS hostname label for Forgejo Git-over-SSH."
}

variable "forgejo_ssh_load_balancer_ip" {
  type        = string
  default     = "10.1.12.21"
  description = "Kubernetes LoadBalancer IP for the Forgejo SSH service."
}

variable "forgejo_ssh_public_port" {
  type        = number
  default     = 22
  description = "WAN TCP port advertised for Forgejo Git-over-SSH."
}

resource "unifi_dynamic_dns" "forgejo_ssh_public" {
  count = var.cloudflare_ddns_login != null && var.cloudflare_ddns_password != null ? 1 : 0

  site      = var.site
  service   = "cloudflare"
  interface = "wan"
  host_name = "${var.forgejo_ssh_public_hostname}.${var.dns_domain}"
  login     = var.cloudflare_ddns_login
  password  = var.cloudflare_ddns_password
}

resource "unifi_port_forward" "forgejo_ssh" {
  site     = var.site
  name     = "Forgejo Git SSH"
  protocol = "tcp"

  wan = {
    interface  = "wan"
    ip_address = "any"
    port       = tostring(var.forgejo_ssh_public_port)
  }

  forward = {
    ip   = var.forgejo_ssh_load_balancer_ip
    port = "22"
  }
}
