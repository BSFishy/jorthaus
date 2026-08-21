terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "0.42.0"
    }
  }
}

provider "unifi" {}
