variable "cml_cloud_url" {
  description = "CML controller address (must start with https://)"
  type        = string
}

variable "cml_cloud_user" {
  description = "CML username"
  type        = string
}

variable "cml_cloud_pass" {
  description = "CML password"
  type        = string
  sensitive   = true
}
