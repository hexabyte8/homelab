# Master Recovery Checklist

> **Use this page during an actual recovery.** It assumes the physical server
> (`chronobyte`) and everything on it (Proxmox, VMs, k3s, workloads, PVC data) is a
> total loss — but every cloud/SaaS dependency is still intact and reachable:
> **GitHub, AWS (S3 + IAM), Cloudflare, Bitwarden, and Tailscale.**
>
> This is the condensed, tick-the-box version of the full guide. Each item links back to
> the relevant phase doc for full explanations, troubleshooting, and exact commands.

---

## Part 1 — Overview Checklist (bare minimum)

The absolute minimum path to a fully-restored cluster, in strict order:

- [ ] **0.** Confirm the Bitwarden vault has every credential in [Phase 0](./00-prerequisites.md), and `BW_ACCESS_TOKEN` is set as a GitHub Actions secret
- [ ] **1.** Confirm GitHub, AWS S3, Cloudflare, and Tailscale are all reachable — [Phase 1](./01-external-services.md)
- [ ] **2.** Install Proxmox VE on the new hardware, configure networking, join Tailscale, build the cloud-init VM template — [Phase 2](./02-proxmox-rebuild.md)
- [ ] **3.** Run **Actions → OpenTofu Apply** (`proxmox`, then `cloudflare`, `tailscale`, `aws`) — recreates all 4 VMs, DNS records, both S3 buckets, and the Velero IAM user — [Phase 3](./03-opentofu-apply.md)
- [ ] **4.** Run the k3s Ansible workflows to deploy the control plane and join both workers — [Phase 4](./04-k3s-cluster.md)
- [ ] **5.** Bootstrap Flux CD against this repo and let it reconcile every workload — [Phase 5](./05-flux-bootstrap.md)
- [ ] **6.** Run **Actions → k3s - Patch Cluster Secrets** with `target: bw-auth-token`, wait ~5 min, then run it again with `target: all` — [Phase 6](./06-secrets-restore.md)
- [ ] **8.** Run **Actions → k3s - Velero Cluster Restore** with `dry_run: true`, review, then re-run with `dry_run: false` — restores your actual data — [Phase 8](./08-velero-restore.md)
- [ ] **7.** Work through the [Phase 7 Validation](./07-validation.md) checklist top-to-bottom
- [ ] Clean up any stale Tailscale device entries and confirm Cloudflare Tunnel/Email Routing status

If everything above is green, the homelab is fully recovered — infrastructure, workloads,
and data.

---

## Part 2 — Per-Step Checklist (full rebuild, new hardware)

Use this when the old hardware (SSD/RAM/CPU) is gone entirely and you are starting from a
brand-new box.

### Step 0 — Gather credentials

- [ ] Open Bitwarden, confirm every secret listed in [Phase 0](./00-prerequisites.md) exists (Cloudflare, AWS, Tailscale, SSH/Git, sm-operator bootstrap token)
- [ ] Confirm `BW_ACCESS_TOKEN` exists as a GitHub Actions secret in this repo

### Step 1 — Confirm cloud services are up

- [ ] AWS S3 buckets `chronobyte-homelab-tf-state` and the Velero/game-server backup buckets are reachable
- [ ] Cloudflare zone and API token work (`https://dash.cloudflare.com`)
- [ ] Tailscale admin console reachable, `tag:server`/`tag:ci` ACL tags still exist
- [ ] GitHub repo and Actions are reachable

### Step 2 — Rebuild the physical host

- [ ] Rack/connect the new box, boot Proxmox VE installer, install fresh
- [ ] Configure the Proxmox management network/bridge to match prior LAN addressing
- [ ] Join the Proxmox host to Tailscale (`tag:server`)
- [ ] Create/verify the cloud-init-enabled Ubuntu VM template OpenTofu expects (see [Phase 2](./02-proxmox-rebuild.md) for the exact template steps)
- [ ] Confirm an API token exists for the Proxmox OpenTofu provider

### Step 3 — Provision everything with OpenTofu

Run **Actions → OpenTofu Apply** for each stack (or `tofu apply` locally if Actions is
unavailable), in this order:

- [ ] `proxmox` — creates `k3s-server`, `k3s-agent-1`, `k3s-agent-2`, `game-server` VMs
- [ ] `tailscale` — recreates the auth key + ACL policy used by the new VMs
- [ ] `cloudflare` — recreates DNS A/SRV records
- [ ] `aws` — recreates both S3 buckets (game-server backups + `daggertooth-cluster-backups`) and the `homelab-velero` IAM user/access key
- [ ] Confirm all 4 VMs boot and are reachable over Tailscale SSH

### Step 4 — Deploy k3s

- [ ] Run the k3s server Ansible playbook against `k3s-server`
- [ ] Run the k3s agent Ansible playbook against `k3s-agent-1` and `k3s-agent-2`
- [ ] `kubectl get nodes` shows all 3 nodes `Ready`

### Step 5 — Bootstrap Flux CD

- [ ] `flux bootstrap github --owner=hexabyte8 --repository=homelab --path=k3s/flux/clusters/<cluster>` (see [Phase 5](./05-flux-bootstrap.md) for exact invocation)
- [ ] `flux get kustomizations -A` — everything reconciles (expect `sm-operator`/app Secrets to be missing/broken until Step 6)

### Step 6 — Restore secrets

- [ ] Run **Actions → k3s - Patch Cluster Secrets** with `target: bw-auth-token`
- [ ] Wait ~5 minutes for the sm-operator to sync every `BitwardenSecret`
- [ ] `kubectl get bitwardensecret -A` — all `Ready`
- [ ] Run **Actions → k3s - Patch Cluster Secrets** with `target: all`
- [ ] Run **OpenTofu Apply** for `authentik` if SSO flows/providers need reprovisioning

### Step 8 — Restore data with Velero

- [ ] `kubectl get pods -n velero` — velero + node-agent pods `Running`
- [ ] `velero backup-location get` — `default` is `Available`
- [ ] Run **Actions → k3s - Velero Cluster Restore** with `dry_run: true` — review the plan
- [ ] Re-run with `dry_run: false`
- [ ] Wait for the restore to reach `Completed` (`velero restore get`)
- [ ] Spot-check that PVC data actually came back (e.g. Jellyfin library, Authentik users)

### Step 7 — Validate everything

Work through [Phase 7: Validation](./07-validation.md) in full, including the new
**7.9.1 Velero Backup Health** check. At minimum:

- [ ] All nodes `Ready`, all Flux Kustomizations reconciled
- [ ] Cloudflare Tunnel + DNS resolving, cert-manager issuing certificates
- [ ] Longhorn all volumes healthy
- [ ] Authentik SSO login works
- [ ] Velero BSL `Available`, schedule `Enabled`, restore `Completed`

### Post-recovery cleanup

- [ ] Remove stale/duplicate Tailscale device entries from the old hardware
- [ ] Confirm the daily Velero schedule (`velero-daily-full`, 02:00 UTC) is enabled going forward
- [ ] Trigger one more manual backup (`velero backup create post-recovery-check --wait`) to confirm the full backup path still works end-to-end
