terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }
  backend "s3" {
    bucket         = "chronobyte-homelab-tf-state"
    key            = "homelab/cloudflare/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "homelab-tf-state-lock"
  }
}

provider "cloudflare" {}
