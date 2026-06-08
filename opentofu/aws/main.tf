terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "chronobyte-homelab-tf-state"
    key            = "homelab/aws/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "homelab-tf-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
}
