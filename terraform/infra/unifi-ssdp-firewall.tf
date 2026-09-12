data "unifi_firewall_zone" "internal" {
  name = "Internal"
  site = var.site
}

data "unifi_firewall_zone" "iot" {
  name = "IoT"
  site = var.site
}

data "unifi_firewall_zone" "dmz" {
  name = "Dmz"
  site = var.site
}

resource "unifi_firewall_group" "ssdp_udp" {
  name    = "ssdp-udp"
  site    = var.site
  type    = "port-group"
  members = ["1900"]
}

locals {
  ssdp_networks = {
    personal = { network_id = data.unifi_network.personal.id, zone_id = data.unifi_firewall_zone.internal.id }
    iot      = { network_id = data.unifi_network.iot.id, zone_id = data.unifi_firewall_zone.iot.id }
    homelab  = { network_id = data.unifi_network.homelab.id, zone_id = data.unifi_firewall_zone.dmz.id }
  }
  ssdp_paths = {
    "homelab-to-iot"      = { source = "homelab", destination = "iot" }
    "iot-to-homelab"      = { source = "iot", destination = "homelab" }
    "homelab-to-personal" = { source = "homelab", destination = "personal" }
    "personal-to-homelab" = { source = "personal", destination = "homelab" }
  }
}

resource "unifi_firewall_policy" "ssdp_responses" {
  for_each = local.ssdp_paths

  name                 = "Allow SSDP ${each.value.source} to ${each.value.destination}"
  description          = "Allows UDP/1900 SSDP response traffic from ${each.value.source} to ${each.value.destination}."
  site                 = var.site
  action               = "ALLOW"
  protocol             = "udp"
  ip_version           = "IPV4"
  create_allow_respond = false

  source = {
    zone_id            = local.ssdp_networks[each.value.source].zone_id
    matching_target    = "NETWORK"
    network_ids        = [local.ssdp_networks[each.value.source].network_id]
    port_matching_type = "OBJECT"
    port_group_id      = unifi_firewall_group.ssdp_udp.id
  }

  destination = {
    zone_id            = local.ssdp_networks[each.value.destination].zone_id
    matching_target    = "NETWORK"
    network_ids        = [local.ssdp_networks[each.value.destination].network_id]
    port_matching_type = "OBJECT"
    port_group_id      = unifi_firewall_group.ssdp_udp.id
  }
}
