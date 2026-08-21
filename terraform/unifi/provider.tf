terraform {
  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "0.42.0"
    }
  }
}

provider "unifi" {}
