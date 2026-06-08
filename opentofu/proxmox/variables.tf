variable "proxmox_host" {
  description = "The Proxmox host to deploy to."
  type        = string
  default     = "chronobyte"
}

variable "proxmox_node_address" {
  description = "SSH address of the Proxmox node for writing cloud-init snippets (uses Tailscale SSH)."
  type        = string
  default     = "chronobyte.daggertooth-scala.ts.net"
}

variable "default_vm_password" {
  description = "Default VM password for console access."
  type        = string
  sensitive   = true
}
