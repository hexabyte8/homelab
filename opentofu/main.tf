# OpenTofu uses the 'terraform' block name for HCL backward compatibility.
terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc04"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.24.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2"
    }
  }
  backend "s3" {
    bucket         = "chronobyte-homelab-tf-state"
    key            = "homelab/terraform.tfstate"
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

provider "cloudflare" {
}

provider "tailscale" {
}

provider "aws" {
  region = var.aws_region
}

provider "null" {}

provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_api_token
}
