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
  memory        = 25600 # bumped from 12288: sole remaining agent after
  # k3s-agent-2 was decommissioned to free capacity for a 16Gi Zomboid pod.
  # Host has 31845Mi total; control-plane keeps 4096Mi, leaving ~2.1Gi
  # headroom for the hypervisor (consistent with the ~3Gi headroom it had
  # with all 3 VMs running before this change).
  scsihw   = "virtio-scsi-pci"
  vm_state = "running"
  tags     = "k3s,kubernetes,infrastructure"

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
    # Doubled from 4: the host only has 8 threads (4c/8t), and dropping
    # k3s-agent-2 frees its 4 cores' worth of oversubscription budget.
    # Total vCPU footprint stays the same as before (control-plane 4 +
    # this VM 8 = 12, same ratio as the old 4+4+4).
    cores   = 8
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
