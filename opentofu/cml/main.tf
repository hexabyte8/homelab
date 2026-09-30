# ----------------------
# CML2 provider configuration
# ----------------------
terraform {
  required_version = ">= 1.14"
  required_providers {
    cml2 = {
      source  = "CiscoDevNet/cml2"
      version = "~> 0.9"
    }
  }  
  backend "s3" {
    bucket         = "chronobyte-homelab-tf-state"
    key            = "homelab/cml/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "homelab-tf-state-lock"
  }
}

provider "cml2" {
  address     = var.cml_cloud_url
  username    = var.cml_cloud_user
  password    = var.cml_cloud_pass
}
