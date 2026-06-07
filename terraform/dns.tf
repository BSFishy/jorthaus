resource "unifi_dns_record" "infra" {
  name        = "*.jort.haus"
  enabled     = true
  record_type = "A"
  value       = var.hosts["infra"].ipv4.address
}
