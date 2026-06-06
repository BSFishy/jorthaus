resource "proxmox_virtual_environment_vm" "home" {
  name      = "home"
  node_name = "gaia-05"

  machine = "q35"
  bios    = "ovmf"

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2048
  }

  serial_device {
    device = "socket"
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_file.home_disk_image.id
    file_format  = "raw"
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 20
  }

  agent {
    enabled = true
    timeout = "15m"
    trim    = false
    type    = "virtio"
  }

  initialization {
    datastore_id = "local-lvm"
    interface    = "ide2"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  operating_system {
    type = "l26"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }
}

resource "proxmox_virtual_environment_file" "home_disk_image" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "gaia-05"

  source_file {
    path = "../result/home.qcow2"
  }
}
