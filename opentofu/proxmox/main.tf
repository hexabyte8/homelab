terraform {
  required_version = ">= 1.8.0"
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc04"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.24.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  backend "s3" {
    bucket         = "chronobyte-homelab-tf-state"
    key            = "homelab/proxmox/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "homelab-tf-state-lock"
  }
}

provider "proxmox" {
  pm_api_url                  = "https://chronobyte.daggertooth-scala.ts.net:8006/api2/json"
  pm_tls_insecure             = true
  pm_minimum_permission_check = false
}

provider "tailscale" {}

provider "null" {}
