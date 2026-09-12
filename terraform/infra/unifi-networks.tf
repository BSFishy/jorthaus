locals {
  discovery_networks = {
    homelab  = data.unifi_network.homelab
    personal = data.unifi_network.personal
    iot      = data.unifi_network.iot
  }
}

data "unifi_network" "homelab" {
  name = "Homelab"
  site = var.site
}

data "unifi_network" "personal" {
  name = "Personal"
  site = var.site
}

data "unifi_network" "iot" {
  name = "IoT"
  site = var.site
}

# These existing networks remain manually owned except for multicast discovery.
# Their data sources preserve the existing name and subnet during import.
resource "unifi_network" "discovery" {
  for_each = local.discovery_networks

  name   = each.value.name
  site   = var.site
  subnet = each.value.subnet

  multicast_dns = true
  igmp_snooping = true

  lifecycle {
    ignore_changes = [
      auto_scale,
      dhcp_guarding,
      dhcp_relay,
      dhcp_server,
      domain_name,
      enabled,
      gateway_type,
      internet_access,
      ip_aliases,
      ipv6_aliases,
      ipv6_interface_type,
      ipv6_pd_interface,
      lte_lan,
      nat_outbound_ip_addresses,
      network_isolation,
      setting_preference,
      third_party_gateway,
      vlan,
    ]
  }
}

output "unifi_discovery_networks" {
  description = "mDNS and IGMP snooping settings managed for discovery VLANs."
  value = {
    for name, network in unifi_network.discovery : name => {
      id            = network.id
      multicast_dns = network.multicast_dns
      igmp_snooping = network.igmp_snooping
      subnet        = network.subnet
      vlan          = network.vlan
    }
  }
}
