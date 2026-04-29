# Phase 0: Prerequisites

> **Do this before touching any hardware.** You cannot recover the homelab without the
> credentials stored in Bitwarden. Confirm every item in this checklist exists in the
> vault before proceeding.

---

## What is Bitwarden?

[Bitwarden](https://bitwarden.com) is the password and secrets manager used to store all
credentials for this homelab. All secrets (API keys, passwords, SSH keys) are stored there
so they survive hardware failures.

If you are unfamiliar with Bitwarden, see the [Bitwarden technology guide](./technologies/bitwarden.md).

---

## Credential Checklist

Log in to [vault.bitwarden.com](https://vault.bitwarden.com) and confirm each of the
following items exists.

### OpenTofu / Proxmox

| Secret | Where Used | Notes |
|--------|-----------|-------|
| `PM_API_TOKEN_ID` | Proxmox provider auth | Format: `user@pam!tokenname` (e.g. `terraform@pam!mytoken`) |
| `PM_API_TOKEN_SECRET` | Proxmox provider auth | UUID generated when creating the Proxmox API token |
| `DEFAULT_VM_PASSWORD` | Console password on all VMs | Set via cloud-init; used as fallback if SSH fails |

### Cloudflare

| Secret | Where Used | Notes |
|--------|-----------|-------|
| `CLOUDFLARE_API_TOKEN` | OpenTofu Cloudflare provider | Needs `Zone:Edit` and `DNS:Edit` permissions |
| `CLOUDFLARE_ZONE_ID` | OpenTofu — identifies the DNS zone | Found in the Cloudflare dashboard under your domain |
| `CLOUDFLARE_ZONE_NAME` | OpenTofu variable | Your public domain name (e.g. `example.com`) |
| `CLOUDFLARE_ACCOUNT_ID` | OpenTofu Cloudflare provider | Found in the Cloudflare dashboard sidebar |

### AWS

| Secret | Where Used | Notes |
|--------|-----------|-------|
| `AWS_ACCESS_KEY_ID` | S3 state backend + S3 backup access | IAM user credential |
| `AWS_SECRET_ACCESS_KEY` | S3 state backend + S3 backup access | IAM user credential |
| `S3_BACKUP_BUCKET_NAME` | OpenTofu + backup scripts | Name of the game server backup bucket |

### Tailscale

| Secret | Where Used | Notes |
|--------|-----------|-------|
| `TAILSCALE_API_KEY` | OpenTofu Tailscale provider | Create at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) |
| `TAILSCALE_OAUTH_CLIENT_ID` | GitHub Actions CI connectivity | OAuth client with `tag:ci` scope |
| `TAILSCALE_OAUTH_CLIENT_SECRET` | GitHub Actions CI connectivity | Corresponding OAuth secret |
| Tailscale Operator OAuth Client ID | Kubernetes Tailscale operator | Used in Phase 6 — manages k8s service exposure |
| Tailscale Operator OAuth Client Secret | Kubernetes Tailscale operator | Used in Phase 6 |

### SSH / Git

| Secret | Where Used | Notes |
|--------|-----------|-------|
| Flux SSH deploy key (private) | Flux pulls from GitHub | ed25519 private key; do NOT share |
| Flux SSH deploy key (public) | Registered in GitHub repo | Must be added to `hexabyte8/homelab → Settings → Deploy keys` |

### GitHub

| Secret | Where Used | Notes |
|--------|-----------|-------|
| `BW_ACCESS_TOKEN` | GitHub Actions → Bitwarden SM | Set as a **GitHub Actions repository secret** in `hexabyte8/homelab` |

> **Important:** GitHub Actions workflows use Bitwarden Secrets Manager (`bitwarden/sm-action@v2`)
> and pull all other secrets from there at runtime. As long as `BW_ACCESS_TOKEN` is set as a
> repository secret, the CI/CD pipelines are self-contained and can run without manual intervention.

---

## Tools You Need on Your Local Machine

Before starting recovery, ensure these tools are installed on the machine you are using
to run commands (your laptop, a jump box, etc.):

| Tool | Install | Why Needed |
|------|---------|-----------|
| `tailscale` | [tailscale.com/download](https://tailscale.com/download) | Required to reach VMs over the private network |
| `ssh` | Built into Linux/macOS; [OpenSSH for Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse) | SSH into VMs and Proxmox |
| `kubectl` | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) | Interact with the Kubernetes cluster |
| `tofu` (OpenTofu) | [get.opentofu.org](https://get.opentofu.org) | Only needed for Option B (manual run) |
| `ansible` | `pip install ansible` | Only needed for Option B (manual run) |
| `aws` CLI | [docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | Verify S3 backups |

> **Note:** If using the recommended GitHub Actions path (Option A), you only need `tailscale`
> and `ssh` on your local machine. GitHub Actions handles the rest.

---

## GitHub Actions Secret

The one secret that must be manually verified before using GitHub Actions is:

1. Go to [github.com/hexabyte8/homelab](https://github.com/hexabyte8/homelab)
2. Navigate to **Settings → Secrets and variables → Actions**
3. Confirm `BW_ACCESS_TOKEN` is listed under **Repository secrets**

If it is missing:
1. Get the Bitwarden Secrets Manager access token from your Bitwarden vault
2. Click **New repository secret**
3. Name: `BW_ACCESS_TOKEN`, Value: paste the token
4. Click **Add secret**

---

## Flux SSH Deploy Key

Flux (the GitOps engine) needs an SSH key to pull code from the private GitHub repository.

**Verify the public key is registered in GitHub:**
1. Go to [github.com/hexabyte8/homelab/settings/keys](https://github.com/hexabyte8/homelab/settings/keys)
2. Confirm an ed25519 deploy key exists with **read access**
3. If missing, you will add it during [Phase 5: Flux Bootstrap](./05-flux-bootstrap.md)

---

## Proceed to Phase 1

Once you have confirmed all credentials exist in Bitwarden and the `BW_ACCESS_TOKEN` GitHub
secret is set, proceed to [Phase 1: Verify External Services](./01-external-services.md).
