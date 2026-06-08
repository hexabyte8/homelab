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

variable "admin_email" {
  description = "Admin email address for Cloudflare Email Routing destination."
  type        = string
  sensitive   = true
}

variable "public_ip" {
  description = "The public IP address of the homelab."
  type        = string
  sensitive   = true
}
