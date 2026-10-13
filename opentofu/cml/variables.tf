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

variable "default_vm_password" {
  description = "Password for the ansible user on the lab's IOS devices (also used as the enable secret)."
  type        = string
  sensitive   = true
}
