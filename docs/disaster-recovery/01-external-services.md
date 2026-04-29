# Phase 1: Verify External Services

> **No hardware needed.** Do this first to confirm you have a valid starting point before
> spending time rebuilding hardware.
>
> **Time estimate:** ~10 minutes

---

## Why This Step Matters

This homelab depends on several cloud services that store its state. Before touching any
hardware, verify that these services are intact. If any of them has been deleted or is
inaccessible, the recovery process will need adjustments.

---

## 1.1 AWS S3 State Backend

The S3 bucket `chronobyte-homelab-tf-state` stores the **infrastructure state** — it remembers
what resources (VMs, DNS records, S3 buckets) OpenTofu has already created and what their
current settings are. State locking is provided by the DynamoDB table `homelab-tf-state-lock`.

**What to check:**

1. Log in to the [AWS S3 console](https://s3.console.aws.amazon.com/s3/) with your credentials
2. Confirm the bucket **`chronobyte-homelab-tf-state`** exists in `us-east-1`
3. Navigate into the bucket and open `homelab/terraform.tfstate`
4. Confirm the state file is non-empty and recent

Or via AWS CLI:
```bash
export AWS_ACCESS_KEY_ID="<AWS_ACCESS_KEY_ID from Bitwarden>"
export AWS_SECRET_ACCESS_KEY="<AWS_SECRET_ACCESS_KEY from Bitwarden>"

aws s3 ls s3://chronobyte-homelab-tf-state/homelab/ --region us-east-1
```

**If the state file is missing:**

This is rare since S3 is independent of your hardware. If it happened:
- All cloud resources (Cloudflare records, S3 bucket) likely still exist from the last apply
- After Phase 3, you may need to re-import resources:
  ```bash
  tofu import proxmox_vm_qemu.k3s-server chronobyte/qemu/102
  ```
  See [Phase 3: OpenTofu Apply](./03-opentofu-apply.md#state-drift) for details.

**Reference:** [OpenTofu S3 backend documentation](https://opentofu.org/docs/language/settings/backends/s3/)

---

## 1.2 GitHub Repository

GitHub stores all Kubernetes manifests and workflow definitions. Without it, Flux cannot
sync and GitHub Actions cannot run.

**What to check:**

1. Visit [https://github.com/hexabyte8/homelab](https://github.com/hexabyte8/homelab)
2. Confirm the `main` branch is intact with recent commits
3. Navigate to **Settings → Deploy keys** and confirm the Flux SSH deploy key (ed25519) exists
   - If missing, you will add it in [Phase 5: Flux Bootstrap](./05-flux-bootstrap.md)

**If the repository is inaccessible:**

- Log in to [github.com](https://github.com) with your account
- Check [status.github.com](https://www.githubstatus.com/) for outages
- If the repository was deleted, you cannot proceed — contact GitHub support

**Reference:** [GitHub documentation](https://docs.github.com)

---

## 1.3 Cloudflare

Cloudflare manages public DNS records for the homelab domain. These will be recreated
by OpenTofu in Phase 3 — no manual action is needed here, just confirm access.

**What to check:**

1. Log in to [dash.cloudflare.com](https://dash.cloudflare.com)
2. Confirm your domain zone is listed and shows **Active** status
3. Note the **Zone ID** and **Account ID** from the sidebar — these go in Bitwarden
4. If existing DNS records are shown, they will be managed (and possibly updated) by OpenTofu

**If the domain zone is missing:**

- Cloudflare zones are independent of your hardware — this would be very unusual
- If somehow deleted, you would need to re-add the domain to Cloudflare and update nameservers
  at your domain registrar

**Reference:** [Cloudflare documentation](https://developers.cloudflare.com/dns/)

---

## 1.4 Tailscale

Tailscale is the private network that connects all VMs to each other and to your devices.
The tailnet (`tailnet.ts.net`) and its configuration persist independently of the hardware.

**What to check:**

1. Log in to [login.tailscale.com/admin](https://login.tailscale.com/admin)
2. Confirm the tailnet `tailnet.ts.net` is listed
3. Under **Machines**, old (destroyed) VM entries will show as offline — you can delete them
   after the new VMs are created
4. Navigate to **Settings → OAuth clients** and confirm the CI OAuth client (`tag:ci`) exists

**If OAuth clients are missing:**

You will need to create a new one:
1. Go to **Settings → OAuth clients → Generate OAuth client**
2. Scope: `Devices` write, `Keys` write, tag `tag:ci`
3. Save the Client ID and Client Secret to Bitwarden

**What Tailscale key types look like:**

| Key Type | Format | Used For |
|----------|--------|---------|
| API key | `tskey-api-...` | OpenTofu provider authentication |
| Auth key | `tskey-auth-...` | VMs joining the tailnet |
| OAuth client ID | Short alphanumeric string | CI workflows (GitHub Actions) |
| OAuth client secret | `tskey-client-...` | CI workflows (GitHub Actions) |

**Reference:** [Tailscale documentation](https://tailscale.com/kb/)

---

## 1.5 AWS S3

AWS S3 stores game server backups. The bucket is created by OpenTofu, so this step just
confirms AWS access is still working.

**What to check:**

1. Log in to [console.aws.amazon.com](https://console.aws.amazon.com)
2. Navigate to **S3** and confirm the backup bucket exists
3. If you have the AWS CLI:
   ```bash
   aws s3 ls --region us-east-1
   ```

**If the bucket is missing:** OpenTofu will recreate it in Phase 3. Existing backup objects
are stored inside the bucket — if the bucket was deleted, those backups may be gone unless
AWS versioning saved them.

**Reference:** [AWS S3 documentation](https://docs.aws.amazon.com/s3/)

---

## Summary Checklist

Before proceeding to Phase 2, confirm:

- [ ] AWS S3 state bucket `chronobyte-homelab-tf-state` exists with `homelab/terraform.tfstate`
- [ ] GitHub repository `hexabyte8/homelab` is accessible on `main` branch
- [ ] Cloudflare dashboard shows the domain zone as Active
- [ ] Tailscale admin shows tailnet `tailnet.ts.net` 
- [ ] Tailscale CI OAuth client exists (or you have created a new one)
- [ ] AWS console is accessible and credentials are valid
- [ ] `BW_ACCESS_TOKEN` is set as a GitHub Actions repository secret

---

## Proceed to Phase 2

→ [Phase 2: Proxmox Server Rebuild](./02-proxmox-rebuild.md)
