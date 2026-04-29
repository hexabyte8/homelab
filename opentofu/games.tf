resource "proxmox_vm_qemu" "game-server" {
  name          = "game-server"
  vmid          = "104"
  target_node   = var.proxmox_host
  clone         = "VM 9000"
  full_clone    = true
  os_type       = "cloud-init"
  agent         = 1
  agent_timeout = 180
  memory        = 8192
  scsihw        = "virtio-scsi-pci"
  vm_state      = "stopped"
  tags          = "gameserver"

  ciuser     = "ubuntu"
  cipassword = var.default_vm_password
  cicustom   = "vendor=local:snippets/main.yaml"
  ciupgrade  = true
  nameserver = "8.8.8.8"
  ipconfig0  = "ip=dhcp"

  serial {
    id = 0
  }

  cpu {
    cores   = 4
    sockets = 1
  }

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "500G"
        }
      }
    }
    ide {
      ide1 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  depends_on = [null_resource.cloudinit_snippet]
}
