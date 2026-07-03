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
      usb = list(object({
        host    = optional(string)
        mapping = optional(string)
        usb3    = optional(bool)
      }))
      hostpci = list(object({
        device   = string
        id       = optional(string)
        mapping  = optional(string)
        mdev     = optional(string)
        pcie     = optional(bool)
        rom_file = optional(string)
        rombar   = optional(bool)
        xvga     = optional(bool)
      }))
      dataDisks = list(object({
        interface   = string
        datastoreId = string
        size        = number
        serial      = optional(string)
        cache       = optional(string)
        backup      = optional(bool)
        replicate   = optional(bool)
        discard     = optional(string)
        iothread    = optional(bool)
        ssd         = optional(bool)
      }))
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

  dynamic "disk" {
    for_each = each.value.proxmox.dataDisks

    content {
      datastore_id = disk.value.datastoreId
      interface    = disk.value.interface
      size         = disk.value.size
      serial       = try(disk.value.serial, null)
      cache        = try(disk.value.cache, null)
      backup       = try(disk.value.backup, null)
      replicate    = try(disk.value.replicate, null)
      discard      = try(disk.value.discard, null)
      iothread     = try(disk.value.iothread, null)
      ssd          = try(disk.value.ssd, null)
    }
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

  dynamic "usb" {
    for_each = each.value.proxmox.usb

    content {
      host    = try(usb.value.host, null)
      mapping = try(usb.value.mapping, null)
      usb3    = try(usb.value.usb3, null)
    }
  }

  dynamic "hostpci" {
    for_each = each.value.proxmox.hostpci

    content {
      device   = hostpci.value.device
      id       = try(hostpci.value.id, null)
      mapping  = try(hostpci.value.mapping, null)
      mdev     = try(hostpci.value.mdev, null)
      pcie     = try(hostpci.value.pcie, null)
      rom_file = try(hostpci.value.rom_file, null)
      rombar   = try(hostpci.value.rombar, null)
      xvga     = try(hostpci.value.xvga, null)
    }
  }
}
