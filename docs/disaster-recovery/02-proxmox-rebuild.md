# Phase 2: Proxmox Server Rebuild

> **Time estimate:** 30–45 minutes (excluding Proxmox ISO download time)
>
> **What you need:**
> - A USB drive (4 GB or larger)
> - Physical access to the server to boot from USB
> - The server's existing static IP plan (192.168.1.10/24)

---

## What is Proxmox VE?

Proxmox Virtual Environment (VE) is the **hypervisor** — the operating system that runs
directly on the physical hardware and allows you to create and manage virtual machines (VMs).

Think of it like this:
- The **physical server** is a computer with a lot of RAM and CPU power
- **Proxmox** runs on that computer and acts as a manager
- **Virtual Machines** are "computers inside the computer" that Proxmox creates and runs

Not familiar with Proxmox? See the [Proxmox technology guide](./technologies/proxmox.md).

---

## 2.1 Install Proxmox VE

### Step 1: Download the Proxmox VE ISO

1. Go to [proxmox.com/downloads](https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso)
2. Download the latest **Proxmox VE ISO Installer** (e.g., `proxmox-ve_8.x-1.iso`)
3. Verify the checksum if provided

### Step 2: Flash to USB

On Linux/macOS:
```bash
# Replace /dev/sdX with your USB device (use 'lsblk' to identify it)
# WARNING: This will erase all data on the USB drive
sudo dd if=proxmox-ve_8.x-1.iso of=/dev/sdX bs=4M status=progress && sync
```

On Windows: Use [Rufus](https://rufus.ie/) or [Balena Etcher](https://etcher.balena.io/)
to write the ISO to the USB drive in **DD mode**.

### Step 3: Boot and Install

1. Insert the USB into the server and reboot
2. Press the appropriate key to open the boot menu (usually F8, F11, F12, or Del)
3. Select the USB drive to boot from
4. In the Proxmox installer, choose **Install Proxmox VE (Graphical)**

**Installer settings:**

| Setting | Value |
|---------|-------|
| Target disk | Your primary SSD/HDD |
| Country | Your country |
| Timezone | Your timezone |
| Hostname (FQDN) | `chronobyte.local` |
| IP Address | `192.168.1.10/24` |
| Gateway | `192.168.1.254` |
| DNS Server | `8.8.8.8` |
| Root password | Choose a strong password and save it to Bitwarden |

5. Complete the installation and reboot
6. Remove the USB drive when prompted

### Step 4: Access the Web UI

Open a browser and navigate to:
```
https://192.168.1.10:8006
```

Accept the self-signed certificate warning. Log in with:
- **Username:** `root`
- **Password:** the root password you set during installation
- **Realm:** `Linux PAM standard authentication`

> **Note:** The Proxmox web interface uses HTTPS but with a self-signed certificate.
> Your browser will show a security warning — this is expected. Click "Advanced" → 
> "Proceed to 192.168.1.10" to continue.

**Reference:** [Proxmox Installation Guide](https://pve.proxmox.com/wiki/Installation)

---

## 2.2 Configure the Network Bridge (vmbr0)

Proxmox automatically creates a network bridge called `vmbr0` that all VMs use to
connect to your LAN. Verify it is configured correctly.

**What is a network bridge?**  
A bridge acts like a virtual network switch. The physical network card connects to the
bridge (`vmbr0`), and virtual machines connect to the bridge as if they were plugged
into the same physical switch.

**Verify in the web UI:**
1. Click **Datacenter** → **chronobyte** → **Network** (in the left panel)
2. Confirm `vmbr0` exists with these settings:
   - Type: Linux Bridge
   - Ports/Slaves: your physical NIC name (e.g. `enp3s0` or `eth0`)
   - IP: `192.168.1.10/24`
   - Gateway: `192.168.1.254`

**Expected `/etc/network/interfaces` configuration:**
```
auto lo
iface lo inet loopback

iface enp3s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.1.10/24
    gateway 192.168.1.254
    bridge-ports enp3s0
    bridge-stp off
    bridge-fd 0
```

> To find your physical NIC name, run `ip link show` in the Proxmox shell.

**VM IP address plan** (assigned via cloud-init in Phase 3):

| VM | VMID | Static LAN IP |
|----|------|--------------|
| k3s-agent-1 | 101 | 192.168.1.175/24 |
| k3s-server | 102 | 192.168.1.179/24 |
| k3s-agent-2 | 103 | 192.168.1.180/24 |
| game-server | 104 | DHCP |

All VMs use gateway `192.168.1.254` and DNS `8.8.8.8`.

---

## 2.3 Install Tailscale on the Proxmox Host

**Why Tailscale on the Proxmox host?**  
Terraform connects to Proxmox via its API at `chronobyte.tailnet.ts.net:8006`.
Tailscale MagicDNS resolves that hostname — so Tailscale must be running on the host
before Terraform can reach it.

Not familiar with Tailscale? See the [Tailscale technology guide](./technologies/tailscale.md).

**Install Tailscale:**

From the Proxmox web UI, click **Shell** (top right of the node view) to open a terminal,
or SSH to the LAN IP directly:

```bash
# Run on the Proxmox host as root
curl -fsSL https://tailscale.com/install.sh | sh

# Start Tailscale and connect to the tailnet
tailscale up --ssh --advertise-tags=tag:server
```

A URL will appear — open it in a browser and authenticate with your Tailscale account.

**Verify Tailscale is connected:**

```bash
tailscale status
# Should show: chronobyte   <100.x.x.x>   ...   online
```

**Verify MagicDNS resolution from another device:**

From your laptop (which must also be on the same tailnet):
```bash
ping chronobyte.tailnet.ts.net
```

If this responds, Terraform will be able to reach Proxmox.

**Reference:** [Tailscale Install on Linux](https://tailscale.com/download/linux)

---

## 2.4 Create the Proxmox API Token

Terraform authenticates to Proxmox using an API token (not a password). You created
this token before and stored it in Bitwarden. Now you need to recreate it with the
same name so the Bitwarden credentials still work.

**Create the API token:**

1. In the Proxmox web UI, navigate to: **Datacenter → Permissions → API Tokens**
2. Click **Add**
3. Set:
   - **User:** `root@pam`
   - **Token ID:** use the value from `PM_API_TOKEN_ID` in Bitwarden
     (everything after the `!`, e.g. if ID is `terraform@pam!mytoken`, use `mytoken`)
   - **Privilege Separation:** **uncheck** this (the token needs full permissions)
4. Click **Add**
5. Proxmox will show the secret UUID **once** — copy it
6. Compare with `PM_API_TOKEN_SECRET` in Bitwarden:
   - If they match: great, nothing to update
   - If they don't match: **update Bitwarden** with the new secret value

> **What is privilege separation?**  
> When enabled, an API token has fewer permissions than the user who created it.
> Disabling it means the token has the same permissions as `root@pam` — which Terraform
> needs to create and manage VMs.

**Reference:** [Proxmox API Token documentation](https://pve.proxmox.com/wiki/User_Management#pveum_tokens)

---

## 2.5 Enable the Snippets Storage Directory

Terraform writes a cloud-init configuration file (called a "snippet") to the Proxmox
host at `/var/lib/vz/snippets/main.yaml`. This snippet is read by each VM during
first boot to install Tailscale.

**What is cloud-init?**  
Cloud-init is a standard way to configure VMs on first boot. It's how VMs receive
their hostname, IP address, SSH keys, and run startup scripts without manual
intervention.

Enable Snippets in the Proxmox web UI:
1. Navigate to **Datacenter → Storage → local → Edit**
2. Under **Content**, enable **Snippets**
3. Click **OK**

Or via the Proxmox shell:
```bash
pvesm set local --content images,rootdir,vztmpl,backup,snippets,iso
```

---

## 2.6 Create the Ubuntu 24.04 Cloud-Init VM Template (VM 9000)

All VMs are cloned from a template called **VM 9000**. This template must be created
manually before Terraform can clone from it. Run these commands on the Proxmox host shell.

**What is a VM template?**  
Instead of installing Ubuntu fresh on each VM, we create a single "golden image" with
Ubuntu pre-installed and convert it to a template. Terraform then clones this template
for each VM, which is much faster than a full install.

```bash
# Step 1: Download Ubuntu 24.04 LTS (Noble Numbat) cloud image
# Cloud images are pre-installed minimal OS images designed for use in cloud environments
cd /tmp
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Verify the download (recommended)
sha256sum noble-server-cloudimg-amd64.img
# Compare with: https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
```

```bash
# Step 2: Create a new VM with VMID 9000
qm create 9000 \
  --name "VM 9000" \
  --memory 2048 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --serial0 socket \
  --vga serial0 \
  --ostype l26
```

```bash
# Step 3: Import the downloaded cloud image as the VM's primary disk
qm set 9000 --scsi0 local-lvm:0,import-from=/tmp/noble-server-cloudimg-amd64.img

# Step 4: Add a cloud-init drive (IDE1) — this is where cloud-init config is injected
qm set 9000 --ide1 local-lvm:cloudinit

# Step 5: Set the boot order to boot from the disk
qm set 9000 --boot order=scsi0

# Step 6: Enable the QEMU guest agent (allows Proxmox to communicate with the VM)
qm set 9000 --agent 1

# Step 7: Convert the VM to a template (prevents accidental modification)
qm template 9000
```

**Verify the template was created:**

In the Proxmox web UI, you should now see **VM 9000** in the left sidebar with a
template icon (stacked squares icon).

> **Note:** If you see an error about the disk already existing, run:
> `qm destroy 9000 --purge` and start over.

**Reference:** [Proxmox Cloud-Init Support](https://pve.proxmox.com/wiki/Cloud-Init_Support)  
**Reference:** [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/)

---

## Summary Checklist

Before proceeding to Phase 3:

- [ ] Proxmox VE is installed and web UI is accessible at `https://192.168.1.10:8006`
- [ ] `vmbr0` network bridge is configured and VMs can reach the LAN
- [ ] Tailscale is installed on the Proxmox host and shows as online in the admin console
- [ ] `ping chronobyte.tailnet.ts.net` responds from your laptop
- [ ] Proxmox API token created with ID matching `PM_API_TOKEN_ID` in Bitwarden
- [ ] Local storage has **Snippets** enabled
- [ ] VM template 9000 created (Ubuntu 24.04 cloud-init image)

---

## Proceed to Phase 3

→ [Phase 3: OpenTofu Apply](./03-opentofu-apply.md)
