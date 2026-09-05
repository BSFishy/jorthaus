terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.2"
    }

    b2 = {
      source  = "backblaze/b2"
      version = "~> 0.13"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
