variable "grafana_client_secret" {
  description = "OAuth2 client secret for the Grafana provider. Rotated weekly by the secrets-rotation workflow and stored in BWS."
  type        = string
  sensitive   = true
}

variable "actual_client_secret" {
  description = "OAuth2 client secret for the Actual Budget provider. Rotated weekly by the secrets-rotation workflow and stored in BWS."
  type        = string
  sensitive   = true
}

variable "mealie_client_secret" {
  description = "OAuth2 client secret for the Mealie provider. Rotated weekly by the secrets-rotation workflow and stored in BWS."
  type        = string
  sensitive   = true
  default     = ""
}

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
