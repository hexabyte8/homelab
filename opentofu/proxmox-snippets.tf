locals {
  cloudinit_snippet = templatefile("${path.module}/templates/main.yaml.tpl", {
    tailscale_auth_key = tailscale_tailnet_key.vm_auth.key
  })
}

resource "null_resource" "cloudinit_snippet" {
  triggers = {
    snippet_hash = sha256(local.cloudinit_snippet)
  }

  provisioner "local-exec" {
    environment = {
      SNIPPET_CONTENT = local.cloudinit_snippet
      PROXMOX_HOST    = var.proxmox_node_address
    }
    command = "printf '%s' \"$SNIPPET_CONTENT\" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@\"$PROXMOX_HOST\" 'cat > /var/lib/vz/snippets/main.yaml'"
  }
}
