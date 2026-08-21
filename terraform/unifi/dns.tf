variable "dns_domain" {
  type        = string
  description = "DNS suffix used for per-host UniFi records."
}

variable "site" {
  type        = string
  default     = "default"
  description = "UniFi site name that owns the DNS records."
}

variable "dns_hosts" {
  type        = map(string)
  default     = {}
  description = "Static hostname to IPv4 mapping used to create UniFi DNS records."
}

resource "unifi_dns_record" "host_ipv4" {
  for_each = var.dns_hosts

  site        = var.site
  name        = "${each.key}.${var.dns_domain}"
  record_type = "A"
  value       = each.value
}

output "dns_hosts" {
  description = "Hostname to IPv4 mapping used to create UniFi DNS records."
  value       = var.dns_hosts
}

output "dns_record_fqdns" {
  description = "Fully qualified DNS records managed in UniFi."
  value = {
    for name, record in unifi_dns_record.host_ipv4 :
    name => record.name
  }
}
