# Tailscale VM auth key — used by cloud-init to join VMs to the tailnet on first boot.
# Lives here (not in the tailscale stack) because it is only consumed by Proxmox VMs.
resource "tailscale_tailnet_key" "vm_auth" {
  reusable            = true
  ephemeral           = false
  preauthorized       = true
  expiry              = 7776000 # 90 days
  description         = "Cloud-init VM auth key"
  tags                = ["tag:server"]
  recreate_if_invalid = "always"
}
