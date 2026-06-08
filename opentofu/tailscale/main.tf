terraform {
  required_version = ">= 1.8.0"
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.24.0"
    }
  }
  backend "s3" {
    bucket         = "chronobyte-homelab-tf-state"
    key            = "homelab/tailscale/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "homelab-tf-state-lock"
  }
}

provider "tailscale" {}
