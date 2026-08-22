variable "cloudflare_zone_id" {
  type        = string
  default     = null
  description = "Cloudflare zone ID for jort.haus."
}

variable "cloudflare_blocked_subdomains" {
  type        = set(string)
  default     = ["node", "service"]
  description = "Subdomains that should resolve publicly to 0.0.0.0 to prevent wildcard proxy matches."
}

resource "cloudflare_dns_record" "blocked_subdomain" {
  for_each = var.cloudflare_zone_id == null ? [] : var.cloudflare_blocked_subdomains

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "A"
  content = "0.0.0.0"
  ttl     = 1
  proxied = false
}

output "cloudflare_blocked_subdomains" {
  description = "Cloudflare DNS records used to block public wildcard matches for internal subdomains."
  value = {
    for name, record in cloudflare_dns_record.blocked_subdomain :
    name => record.name
  }
}
