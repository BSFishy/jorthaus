variable "hosts" {
  type = map(object({
    hostName = string
    ipv4 = object({
      address      = string
      prefixLength = number
      gateway      = string
    })
    imageTargetKey = string
    proxmox = object({
      nodeName        = string
      cpuCores        = number
      memory          = number
      diskSize        = number
      machine         = string
      bios            = string
      bridge          = string
      imageDatastore  = string
      vmDiskDatastore = string
    })
  }))
}

variable "imageTargets" {
  type = map(object({
    nodeName       = string
    imageDatastore = string
  }))
}

resource "proxmox_virtual_environment_file" "bootstrap_disk_image" {
  for_each = var.imageTargets

  content_type = "import"
  datastore_id = each.value.imageDatastore
  node_name    = each.value.nodeName

  source_file {
    path      = "../result/bootstrap.qcow2"
    file_name = "bootstrap.qcow2"
  }
}

resource "proxmox_virtual_environment_vm" "host" {
  for_each = var.hosts

  name      = each.value.hostName
  node_name = each.value.proxmox.nodeName

  machine = each.value.proxmox.machine
  bios    = each.value.proxmox.bios

  cpu {
    cores = each.value.proxmox.cpuCores
    type  = "max"
  }

  memory {
    dedicated = each.value.proxmox.memory
  }

  serial_device {
    device = "socket"
  }

  efi_disk {
    datastore_id = each.value.proxmox.vmDiskDatastore
    type         = "4m"
  }

  disk {
    datastore_id = each.value.proxmox.vmDiskDatastore
    file_id      = proxmox_virtual_environment_file.bootstrap_disk_image[each.value.imageTargetKey].id
    file_format  = "raw"
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = each.value.proxmox.diskSize
  }

  agent {
    enabled = true
    timeout = "15m"
    trim    = false
    type    = "virtio"
  }

  initialization {
    datastore_id = each.value.proxmox.vmDiskDatastore
    interface    = "ide2"

    ip_config {
      ipv4 {
        address = "${each.value.ipv4.address}/${tostring(each.value.ipv4.prefixLength)}"
        gateway = each.value.ipv4.gateway
      }
    }
  }

  operating_system {
    type = "l26"
  }

  network_device {
    bridge = each.value.proxmox.bridge
    model  = "virtio"
  }
}
