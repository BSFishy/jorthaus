resource "unifi_dns_record" "infra" {
  name        = "*.jort.haus"
  enabled     = true
  record_type = "A"
  value       = var.hosts["infra"].ipv4.address
}

resource "unifi_port_forward" "infra_https" {
  name     = "infra-https"
  protocol = "tcp"

  wan = {
    interface  = "wan"
    ip_address = "any"
    port       = "443"
  }

  forward = {
    ip   = var.hosts["infra"].ipv4.address
    port = "443"
  }
}
