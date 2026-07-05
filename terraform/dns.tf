locals {
  infra_global_ipv6_candidates = [
    for address in flatten(proxmox_virtual_environment_vm.host["infra"].ipv6_addresses) : address
    if address != "::1" && !startswith(lower(address), "fe80:")
  ]

  infra_global_ipv6 = try(local.infra_global_ipv6_candidates[0], null)
}

resource "unifi_dns_record" "infra" {
  name        = "*.jort.haus"
  enabled     = true
  record_type = "A"
  value       = var.hosts["infra"].ipv4.address
}

resource "unifi_dns_record" "infra_ipv6" {
  count       = local.infra_global_ipv6 != null ? 1 : 0
  name        = "*.jort.haus"
  enabled     = true
  record_type = "AAAA"
  value       = local.infra_global_ipv6
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
