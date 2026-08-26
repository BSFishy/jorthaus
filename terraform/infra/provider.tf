terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.8"
    }

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
provider "cloudflare" {}
