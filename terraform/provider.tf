terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.108.0"
    }
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "0.42.0"
    }
  }
}

provider "proxmox" {}
provider "unifi" {}
