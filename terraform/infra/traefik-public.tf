variable "traefik_load_balancer_ip" {
  type        = string
  default     = "10.1.12.20"
  description = "Kubernetes LoadBalancer IP for Traefik."
}

data "cloudflare_ip_ranges" "edge" {}

resource "unifi_firewall_group" "cloudflare_ipv4" {
  name    = "cloudflare-ipv4"
  site    = var.site
  type    = "address-group"
  members = data.cloudflare_ip_ranges.edge.ipv4_cidrs
}

resource "unifi_port_forward" "traefik_http" {
  site     = var.site
  name     = "Traefik HTTP (Cloudflare)"
  protocol = "tcp"

  wan = {
    interface  = "wan"
    ip_address = "any"
    port       = "80"
  }

  forward = {
    ip   = var.traefik_load_balancer_ip
    port = "80"
  }

  source_limiting = {
    enabled           = true
    firewall_group_id = unifi_firewall_group.cloudflare_ipv4.id
  }
}

resource "unifi_port_forward" "traefik_https" {
  site     = var.site
  name     = "Traefik HTTPS (Cloudflare)"
  protocol = "tcp"

  wan = {
    interface  = "wan"
    ip_address = "any"
    port       = "443"
  }

  forward = {
    ip   = var.traefik_load_balancer_ip
    port = "443"
  }

  source_limiting = {
    enabled           = true
    firewall_group_id = unifi_firewall_group.cloudflare_ipv4.id
  }
}
