terraform {
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2026.8.0"
    }

    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.2"
    }
  }
}

provider "authentik" {}
