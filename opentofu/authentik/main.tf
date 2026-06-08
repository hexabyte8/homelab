terraform {
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2"
    }
  }
  backend "s3" {
    bucket         = "chronobyte-homelab-tf-state"
    key            = "homelab/authentik/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "homelab-tf-state-lock"
  }
}

provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_api_token
}
