variable "authentik_url" {
  description = "Base URL of the Authentik instance."
  type        = string
  default     = "https://authentik.chronobyte.net"
}

variable "authentik_api_token" {
  description = "API token for the goauthentik/authentik provider."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_name" {
  description = "The Cloudflare zone name — used to build external_host URLs for proxy providers."
  type        = string
}
