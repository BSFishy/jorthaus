variable "frr_hostname" {
  type        = string
  default     = "unifi-gateway"
  description = "Hostname written into the rendered FRR configuration."
}

variable "frr_router_id" {
  type        = string
  description = "Router ID used by FRR on the gateway."
}

variable "frr_router_as" {
  type        = number
  description = "BGP ASN used by the gateway."
}

variable "frr_node_as" {
  type        = number
  description = "BGP ASN used by the jorthaus nodes."
}

variable "frr_service_subnet" {
  type        = string
  default     = "10.1.11.0/24"
  description = "Service subnet originated by the gateway toward the LAN."
}

variable "frr_neighbors" {
  type = list(object({
    name    = string
    address = string
  }))
  default     = []
  description = "Static list of node BGP neighbors for FRR."
}

variable "frr_output_path" {
  type        = string
  default     = "rendered/frr.conf"
  description = "Path, relative to this module, where the rendered FRR configuration is written locally."
}

variable "frr_enable" {
  type        = bool
  default     = true
  description = "Whether UniFi BGP should be enabled."
}

variable "frr_description" {
  type        = string
  default     = "Jorthaus BGP configuration"
  description = "Description stored with the UniFi BGP configuration."
}

locals {
  rendered_frr_conf = templatefile("${path.module}/frr.conf.tftpl", {
    hostname       = var.frr_hostname
    router_id      = var.frr_router_id
    router_as      = var.frr_router_as
    node_as        = var.frr_node_as
    service_subnet = var.frr_service_subnet
    neighbors      = var.frr_neighbors
  })
}

resource "local_file" "frr_conf" {
  filename = "${path.module}/${var.frr_output_path}"
  content  = local.rendered_frr_conf
}

resource "unifi_bgp" "router" {
  site        = var.site
  enabled     = var.frr_enable
  description = var.frr_description
  config      = local.rendered_frr_conf
}

output "frr_conf_path" {
  description = "Path to the rendered FRR configuration file."
  value       = local_file.frr_conf.filename
}

output "frr_conf_preview" {
  description = "Rendered FRR configuration."
  value       = local.rendered_frr_conf
}

output "frr_bgp_enabled" {
  description = "Whether the UniFi BGP resource is enabled."
  value       = unifi_bgp.router.enabled
}

output "frr_bgp_upload_file_name" {
  description = "Uploaded file name reported by the UniFi provider."
  value       = unifi_bgp.router.upload_file_name
}
