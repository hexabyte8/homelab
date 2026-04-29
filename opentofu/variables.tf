variable "proxmox_host" {
  description = "The Proxmox host to deploy to."
  type        = string
  default     = "chronobyte"
}

variable "public_ip" {
  description = "The public IP address of the homelab."
  type        = string
  sensitive   = true
}

variable "peer_public_ip" {
  description = "Public IP of a peer site (used for IP-allowlisting peer-to-peer traffic)."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "The Cloudflare zone ID."
  type        = string
}

variable "cloudflare_zone_name" {
  description = "The Cloudflare zone name (e.g. example.com)."
  type        = string
}

variable "cloudflare_account_id" {
  description = "The Cloudflare account ID."
  type        = string
}


variable "default_vm_password" {
  description = "default vm password for console access"
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "The AWS region for S3 bucket"
  type        = string
  default     = "us-east-1"
}

variable "proxmox_node_address" {
  description = "SSH address of the Proxmox node for writing cloud-init snippets (uses Tailscale SSH)."
  type        = string
  default     = "chronobyte.daggertooth-scala.ts.net"
}

variable "s3_backup_bucket_name" {
  description = "Name of the S3 bucket for game server backups"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.s3_backup_bucket_name)) && length(var.s3_backup_bucket_name) >= 3 && length(var.s3_backup_bucket_name) <= 63
    error_message = "S3 bucket name must be lowercase, 3-63 characters, start and end with a letter or number, and can only contain lowercase letters, numbers, and hyphens (no underscores)."
  }
}

variable "authentik_url" {
  description = "Base URL of the Authentik instance (used by the goauthentik/authentik provider)."
  type        = string
  default     = "https://authentik.daggertooth-scala.ts.net"
}

variable "authentik_api_token" {
  description = "API token for the goauthentik/authentik provider (akadmin token, identifier=opentofu-provider)."
  type        = string
  sensitive   = true
}

variable "admin_email" {
  description = "Admin email address for Cloudflare Email Routing destination and notifications."
  type        = string
  sensitive   = true
}
