resource "proxmox_vm_qemu" "containerlab" {
  name          = "containerlab"
  vmid          = "105"
  target_node   = var.proxmox_host
  clone         = "VM 9000"
  full_clone    = true
  os_type       = "cloud-init"
  agent         = 1
  agent_timeout = 180
  memory        = 16384
  scsihw        = "virtio-scsi-pci"
  vm_state      = "stopped"
  tags          = "containerlab,network-lab"

  ciuser     = "ubuntu"
  cipassword = var.default_vm_password
  cicustom   = "vendor=local:snippets/main.yaml"
  ciupgrade  = true
  nameserver = "8.8.8.8"
  ipconfig0  = "ip=192.168.1.181/24,gw=192.168.1.254"

  serial {
    id = 0
  }

  # Use host CPU model to expose virtualisation extensions for VM-based NOS images
  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
  }

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "100G"
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
