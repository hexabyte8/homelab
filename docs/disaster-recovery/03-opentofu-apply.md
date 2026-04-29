# Phase 3: OpenTofu Apply

> **Time estimate:** 15 minutes (plus ~5–10 minutes for VMs to boot)
>
> **What this does:** Creates all 4 virtual machines, configures DNS records,
> creates the Tailscale auth key and ACL policy, and creates the S3 backup bucket.

---

## What is OpenTofu?

OpenTofu is an open-source **Infrastructure as Code** tool (a community fork of Terraform). Instead of manually creating VMs
through a web interface, you describe what you want in code (`.tf` files) and
OpenTofu creates it automatically. When you need to rebuild, you just run OpenTofu
again — it recreates everything exactly the same way.

Not familiar with OpenTofu? See the [OpenTofu technology guide](./technologies/opentofu.md).

---

## What OpenTofu Will Create

| Resource | Details |
|----------|---------|
| `k3s-server` (VMID 102) | 4 vCPU, 8 GB RAM, 500 GB disk, IP `<k3s-server-lan-ip>` |
| `k3s-agent-1` (VMID 101) | 4 vCPU, 16 GB RAM, 500 GB disk, IP `<k3s-agent-1-lan-ip>` |
| `k3s-agent-2` (VMID 103) | 4 vCPU, 16 GB RAM, 500 GB disk, IP `<k3s-agent-2-lan-ip>` |
| `game-server` (VMID 104) | 4 vCPU, 16 GB RAM, 500 GB disk, DHCP |
| Cloud-init snippet | Written to `/var/lib/vz/snippets/main.yaml` on Proxmox |
| Tailscale auth key | Reusable, 90-day, pre-authorized, `tag:server` |
| Tailscale ACL policy | Mesh policy: `tag:server`, `tag:ci`, `tag:k8s-operator` |
| Cloudflare DNS A records | Root, traefik, auth, ptero, homestead, files |
| Cloudflare SRV record | `_minecraft._tcp.homestead` |
| AWS S3 bucket | Versioned, AES-256 encrypted, lifecycle rules |

---

## 3.1 Option A — Via GitHub Actions (Recommended)

This is the normal path. The `opentofu-apply.yml` workflow handles all secrets
automatically via Bitwarden and connects to Proxmox via Tailscale.

**Prerequisites:**
- `BW_ACCESS_TOKEN` is set as a GitHub Actions secret (see [Prerequisites](./00-prerequisites.md))
- Proxmox host is online and reachable via `chronobyte.tailnet.ts.net`
- The GitHub Actions runner must be able to reach Tailscale

**Steps:**

1. Go to the GitHub repository: [github.com/hexabyte8/homelab](https://github.com/hexabyte8/homelab)
2. Click **Actions** tab
3. Find **OpenTofu Apply** in the left sidebar
4. Click **Run workflow** → select branch `main` → click **Run workflow**

The workflow will:
1. Pull all secrets from Bitwarden (Proxmox token, Cloudflare token, Tailscale key, AWS keys, etc.)
2. Connect to the Tailscale tailnet (as `tag:ci`) so it can reach Proxmox
3. Run `tofu init` (connects to S3 backend to download state)
4. Run `tofu apply -auto-approve`

**Monitor progress:** Click on the running workflow to see real-time logs.  
**Expected time:** ~5–10 minutes for VMs to clone and boot.

---

## 3.2 Option B — Local OpenTofu Run

Use this if GitHub Actions is unavailable, broken, or you prefer manual control.

**Prerequisites:**
- `tofu` CLI installed
- You are connected to the tailnet (`tailscale up`)
- All secrets available from Bitwarden

```bash
# Install OpenTofu (Ubuntu/Debian)
curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
chmod +x /tmp/install-opentofu.sh
/tmp/install-opentofu.sh --install-method standalone
```

```bash
# Clone the repository
git clone git@github.com:hexabyte8/homelab.git
cd homelab/opentofu
```

```bash
# Create tfvars file (populate values from Bitwarden)
cat > terraform.auto.tfvars <<EOF
cloudflare_zone_id    = "<CLOUDFLARE_ZONE_ID>"
cloudflare_zone_name  = "<CLOUDFLARE_ZONE_NAME>"
cloudflare_account_id = "<CLOUDFLARE_ACCOUNT_ID>"
proxmox_host          = "chronobyte"
default_vm_password   = "<DEFAULT_VM_PASSWORD>"
aws_region            = "us-east-1"
s3_backup_bucket_name = "<S3_BACKUP_BUCKET_NAME>"
EOF
```

```bash
# Export provider credentials as environment variables
# (AWS creds are also used by the S3 state backend)
export TF_VAR_public_ip="$(curl -s https://api.ipify.org)"   # your current public IP
export CLOUDFLARE_API_TOKEN="<CLOUDFLARE_API_TOKEN>"
export AWS_ACCESS_KEY_ID="<AWS_ACCESS_KEY_ID>"
export AWS_SECRET_ACCESS_KEY="<AWS_SECRET_ACCESS_KEY>"
export TAILSCALE_API_KEY="<TAILSCALE_API_KEY>"
export PM_API_TOKEN_ID="<PM_API_TOKEN_ID>"
export PM_API_TOKEN_SECRET="<PM_API_TOKEN_SECRET>"
```

```bash
# Connect to the tailnet so OpenTofu can reach Proxmox
tailscale up

# Initialize OpenTofu (downloads providers, connects to S3 backend)
tofu init

# Preview what will be created/changed (no changes made yet)
tofu plan

# Apply changes (creates everything)
tofu apply
```

> **Tip:** Run `tofu plan` before `tofu apply` to preview changes and
> catch any errors before making modifications to real infrastructure.

---

## 3.3 Understanding Cloud-Init Bootstrap

Each VM boots and automatically runs the cloud-init snippet that OpenTofu wrote
to `/var/lib/vz/snippets/main.yaml`. This snippet does the following **without any
manual intervention**:

1. Installs `qemu-guest-agent` (allows Proxmox to communicate with the VM)
2. Disables IPv6 on `eth0` (prevents flannel VXLAN confusion)
3. Installs Tailscale via the official one-line install script
4. Connects to the tailnet with a pre-authorized auth key and `tag:server` tag

**What is cloud-init?**  
Cloud-init is an industry-standard tool that runs on the first boot of a VM.
It reads configuration from a special "cloud-init drive" attached to the VM and
runs setup tasks automatically. This is how cloud providers (AWS, Azure, GCP) configure
VMs at launch.

**The cloud-init snippet (`opentofu/templates/main.yaml.tpl`):**
```yaml
#cloud-config
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - systemctl restart systemd-sysctl
  # Install Tailscale (one-line from https://tailscale.com/download/)
  - ['sh', '-c', 'curl -fsSL https://tailscale.com/install.sh | sh']
  # Connect to tailnet with pre-authorized key (injected by Terraform)
  - ['tailscale', 'up', '--auth-key=${tailscale_auth_key}', '--advertise-tags=tag:server', '--ssh']
write_files:
  - path: /etc/sysctl.d/10-disable-ipv6.conf
    permissions: '0644'
    owner: root
    content: |
      net.ipv6.conf.eth0.disable_ipv6 = 1
```

> `${tailscale_auth_key}` is replaced by OpenTofu with the actual key value before
> writing the file to Proxmox. The `--ssh` flag enables Tailscale SSH (no SSH keys required).

---

## 3.4 Verify VMs Are Online

After `tofu apply` completes, wait ~5 minutes for VMs to boot and run cloud-init.

**Check Tailscale admin console:**

Go to [login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
and confirm all 4 VMs appear as online:
- `k3s-server`
- `k3s-agent-1`
- `k3s-agent-2`
- `game-server`

**Or use the CLI:**
```bash
tailscale status
# Expected: 4 new machine entries for the VMs, all showing as online
```

**Verify SSH access works:**
```bash
ssh ubuntu@k3s-server.tailnet.ts.net
ssh ubuntu@k3s-agent-1.tailnet.ts.net
ssh ubuntu@k3s-agent-2.tailnet.ts.net
```

> **If VMs don't appear in Tailscale within 10 minutes:**
> 1. Open the Proxmox web UI and check the VM console (click the VM → Console)
> 2. Check cloud-init logs:
>    ```bash
>    # Via Proxmox console or direct LAN SSH using DEFAULT_VM_PASSWORD
>    sudo cat /var/log/cloud-init-output.log | tail -50
>    ```
> 3. Common issues: Proxmox snippet not found, Tailscale auth key expired, no internet access

---

## 3.5 OpenTofu State Drift Recovery {#state-drift}

If the S3 state bucket was accidentally deleted or the state file is missing, you will need to re-import
existing resources after running `tofu apply` for the first time. This is uncommon
since S3 is independent of your physical hardware.

**How to detect this:** `tofu apply` creates resources that already exist, or
shows errors like "resource already exists."

**Re-import existing resources:**
```bash
tofu import proxmox_vm_qemu.k3s-server chronobyte/qemu/102
tofu import proxmox_vm_qemu.k3s-agent-1 chronobyte/qemu/101
tofu import proxmox_vm_qemu.k3s-agent-2 chronobyte/qemu/103
tofu import proxmox_vm_qemu.game-server chronobyte/qemu/104
```

After importing, run `tofu plan` to confirm no unexpected changes are planned.

**Reference:** [OpenTofu import documentation](https://opentofu.org/docs/cli/import/)

---

## Summary Checklist

Before proceeding to Phase 4:

- [ ] `tofu apply` completed without errors
- [ ] All 4 VMs appear as online in the Tailscale admin console
- [ ] SSH to `ubuntu@k3s-server.tailnet.ts.net` succeeds
- [ ] SSH to `ubuntu@k3s-agent-1.tailnet.ts.net` succeeds
- [ ] SSH to `ubuntu@k3s-agent-2.tailnet.ts.net` succeeds
- [ ] Cloudflare DNS records visible in the dashboard
- [ ] S3 bucket visible in AWS console

---

## Proceed to Phase 4

→ [Phase 4: k3s Cluster Setup](./04-k3s-cluster.md)
