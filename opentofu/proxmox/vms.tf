resource "proxmox_vm_qemu" "k3s-server" {
  name          = "k3s-server"
  vmid          = "102"
  target_node   = var.proxmox_host
  clone         = "VM 9000"
  full_clone    = true
  os_type       = "cloud-init"
  agent         = 1
  agent_timeout = 180
  memory        = 4096 # control-plane only, actual usage ~2.8 GB
  scsihw        = "virtio-scsi-pci"
  vm_state      = "running"
  tags          = "k3s,kubernetes,infrastructure"

  ciuser     = "ubuntu"
  cipassword = var.default_vm_password
  cicustom   = "vendor=local:snippets/main.yaml"
  ciupgrade  = true
  nameserver = "8.8.8.8"
  ipconfig0  = "ip=192.168.1.179/24,gw=192.168.1.254"

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

resource "proxmox_vm_qemu" "k3s-agent-1" {
  name          = "k3s-agent-1"
  vmid          = "101"
  target_node   = var.proxmox_host
  clone         = "VM 9000"
  full_clone    = true
  os_type       = "cloud-init"
  agent         = 1
  agent_timeout = 180
  memory        = 12288 # reduced from 16384 (actual usage ~6.7 GB)
  scsihw        = "virtio-scsi-pci"
  vm_state      = "running"
  tags          = "k3s,kubernetes,infrastructure"

  ciuser     = "ubuntu"
  cipassword = var.default_vm_password
  cicustom   = "vendor=local:snippets/main.yaml"
  ciupgrade  = true
  nameserver = "8.8.8.8"
  ipconfig0  = "ip=192.168.1.175/24,gw=192.168.1.254"

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

resource "proxmox_vm_qemu" "k3s-agent-2" {
  name          = "k3s-agent-2"
  vmid          = "103"
  target_node   = var.proxmox_host
  clone         = "VM 9000"
  full_clone    = true
  os_type       = "cloud-init"
  agent         = 1
  agent_timeout = 180
  memory        = 12288 # bumped from 8192 (was hitting 69% capacity with Jellyfin)
  scsihw        = "virtio-scsi-pci"
  vm_state      = "running"
  tags          = "k3s,kubernetes,infrastructure"

  ciuser     = "ubuntu"
  cipassword = var.default_vm_password
  cicustom   = "vendor=local:snippets/main.yaml"
  ciupgrade  = true
  nameserver = "8.8.8.8"
  ipconfig0  = "ip=192.168.1.180/24,gw=192.168.1.254"

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
          size    = "200G"
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
