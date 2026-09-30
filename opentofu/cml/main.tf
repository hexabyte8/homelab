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
}

provider "cml2" {
  address     = var.cml_cloud_url
  username    = var.cml_cloud_user
  password    = var.cml_cloud_pass
}
