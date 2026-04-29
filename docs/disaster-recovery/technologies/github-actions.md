# GitHub Actions — Technology Guide

> This guide explains what GitHub Actions is, how the workflows in this homelab
> work, and how to use them for deployment and automation.
> No prior CI/CD experience required.

---

## What is GitHub Actions?

**GitHub Actions** is GitHub's built-in **CI/CD (Continuous Integration / Continuous
Deployment)** platform. It allows you to automate tasks that run in response to events
in your GitHub repository (like pushing code) or manually.

In this homelab, GitHub Actions workflows automate:
- Running OpenTofu to create/update infrastructure
- Running Ansible playbooks to configure servers
- Deploying Kubernetes manifests

**Why use GitHub Actions instead of running commands manually?**
- Secrets are managed centrally (Bitwarden SM → GitHub Actions)
- No need to install tools locally (OpenTofu, Ansible, kubectl)
- Reproducible — the same steps run the same way every time
- Audit trail — every workflow run is logged with inputs and outputs
- Safe — credentials are never exposed in logs (masked automatically)

**References:**
- [GitHub Actions documentation](https://docs.github.com/en/actions)
- [GitHub Actions quickstart](https://docs.github.com/en/actions/quickstart)
- [Workflow syntax reference](https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions)

---

## Key Concepts

### Workflow

A **workflow** is a YAML file stored in `.github/workflows/` that defines automated
processes. Each workflow has:
- **Triggers** — events that cause the workflow to run
- **Jobs** — groups of steps that run together
- **Steps** — individual commands or actions

### Triggers

Common triggers in this homelab:

```yaml
on:
  # Runs when code is pushed to main branch (only if opentofu/ files changed)
  push:
    branches: [main]
    paths: ['opentofu/**']

  # Runs when a pull request is opened (for review)
  pull_request:
    branches: [main]
    paths: ['opentofu/**']

  # Can be triggered manually from the GitHub UI
  workflow_dispatch:
    inputs:
      target_host:
        description: 'Target hostname'
        required: true
```

`workflow_dispatch` is used for all Ansible workflows — they require manual trigger
because they need a `target_host` input.

### Jobs and Steps

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest    # Run on GitHub's cloud runners
    steps:
      - name: Checkout code
        uses: actions/checkout@v6   # Clone the repository

      - name: Do something
        run: echo "Hello from CI"   # Run a shell command
```

### Actions

**Actions** are reusable, pre-built steps. They are referenced with `uses:`:

| Action | What It Does |
|--------|-------------|
| `actions/checkout@v6` | Clones the repository into the runner |
| `bitwarden/sm-action@v3` | Pulls secrets from Bitwarden Secrets Manager |
| `tailscale/github-action@v3` | Connects the runner to the Tailscale tailnet |
| `opentofu/setup-opentofu@v2` | Installs OpenTofu on the runner |

### Secrets

GitHub Actions **repository secrets** are encrypted values stored in the repository
settings. They are injected as environment variables in workflows.

In this homelab, only ONE secret is stored directly in GitHub:
- `BW_ACCESS_TOKEN` — used to pull all other secrets from Bitwarden SM

All other secrets live in Bitwarden SM and are fetched at runtime.

---

## Workflows in This Homelab

### Terraform Workflows

#### opentofu-plan.yml

**Trigger:** Pull request to `main` (when `opentofu/**` files change) or manual  
**What it does:**
1. Pulls secrets from Bitwarden SM
2. Connects to Tailscale (to reach Proxmox API)
3. Runs `tofu init` (connects to S3 backend)
4. Runs `tofu plan`
5. Posts the plan output as a comment on the PR

**Use case:** Review infrastructure changes before merging a PR.

#### opentofu-apply.yml

**Trigger:** Push to `main` (when `opentofu/**` files change) or manual  
**What it does:**
1. Pulls secrets from Bitwarden SM
2. Connects to Tailscale
3. Runs `tofu init`
4. Runs `tofu apply -auto-approve`

**Use case:** Apply infrastructure changes after PR approval, or manual trigger during recovery.

#### opentofu-destroy.yml

**Trigger:** Manual only  
**What it does:** Runs `tofu destroy` — removes ALL managed infrastructure.  
⚠️ **Dangerous** — only use this if you intend to destroy everything.

#### opentofu-import.yml

**Trigger:** Manual  
**What it does:** Runs `tofu import` to import existing resources into state.  
**Use case:** After a state loss or when resources were created outside Terraform.

### Ansible Workflows

All Ansible workflows follow the same pattern:
1. Pull secrets from Bitwarden SM
2. Connect to Tailscale
3. Generate a dynamic Ansible inventory
4. Run `ansible-playbook` against the target host(s)
5. Post a job summary

#### ansible-k3s.yml

**Input:** `target_host` (e.g., `k3s-server`)  
**Playbook:** `deploy_k3s.yml`  
**Use case:** [Phase 4] Deploy the k3s control plane node

#### ansible-k3s-worker-tailscale.yml

**Inputs:** `worker_host`, `server_host`  
**Playbook:** `deploy_k3s_worker_tailscale.yml`  
**Use case:** [Phase 4] Join a k3s worker node to the cluster

#### ansible-fix-k3s-tailscale-startup.yml

**Input:** `target_hosts` (default: `k3s-server,k3s-agent-1,k3s-agent-2`)  
**Playbook:** `fix_k3s_tailscale_startup.yml`  
**Use case:** [Phase 4] Apply Tailscale startup ordering fix to all nodes

#### ansible-longhorn-prereqs.yml

**Input:** `target_hosts` (default: all k3s nodes)  
**Playbook:** `install_longhorn_prereqs.yml`  
**Use case:** [Phase 4] Install open-iscsi and related packages before Longhorn

#### ansible-s3-backup.yml

**Inputs:** `target_host`, `backup_schedule`  
**Playbook:** `deploy_s3_backup.yml`  
**Use case:** [Phase 6] Set up automated S3 backups on the game server

#### ansible-minecraft.yml

**Input:** `target_host`  
**Playbook:** `deploy_minecraft.yml`  
**Use case:** [Phase 6] Deploy the Minecraft server systemd service

#### ansible-backup-run.yml

**Input:** `target_host`  
**Playbook:** `run_s3_backup.yml`  
**Use case:** Trigger an immediate S3 backup and verify it succeeded

### k3s Manifest Workflow

#### k3s-manifests.yml

**Trigger:** Manual only  
**Purpose:** Deploy or delete specific Kubernetes manifests outside of the normal
GitOps flow (used for bootstrapping or emergency operations)

**Inputs:**
- `action`: `apply` or `delete`
- `manifest_path`: Path to the manifest file (e.g., `k3s/flux/clusters/k3s/apps.yaml`)

**Use case:** [Phase 5] Applying manifests to bootstrap Flux CD.

---

## How to Trigger a Workflow Manually

1. Go to [github.com/hexabyte8/homelab](https://github.com/hexabyte8/homelab)
2. Click the **Actions** tab
3. Find the workflow in the left sidebar (e.g., "Ansible - Deploy k3s")
4. Click **Run workflow** on the right side
5. Fill in any required inputs
6. Click **Run workflow** button

---

## Reading Workflow Logs

When a workflow runs:
1. Click on the workflow run in the Actions tab
2. Click on a job name to expand it
3. Click on any step to see its output

**Important:** Sensitive values (secrets) are automatically replaced with `***` in logs.

### Job Summaries

Many workflows post a **job summary** — a formatted report shown at the bottom of the
workflow run page. These summaries include:
- What was applied
- Any errors
- Output from tools like `tofu plan`

---

## Common Issues

### Workflow fails at "Get Secrets" step

The `BW_ACCESS_TOKEN` GitHub secret is missing or invalid:
1. Check **Settings → Secrets and variables → Actions** that `BW_ACCESS_TOKEN` exists
2. Log in to Bitwarden SM and verify the token is not expired
3. Create a new token if needed and update the GitHub secret

### Tailscale connection fails

The OAuth client credentials have issues:
1. Check the Tailscale admin console for the CI OAuth client
2. Verify the credentials in Bitwarden SM are correct
3. Re-generate OAuth client credentials if needed

### Ansible "SSH connection failed"

1. Verify the target VM is online: check Tailscale admin console
2. Verify the VM hostname is correct in the workflow input
3. Check if cloud-init completed successfully on the VM:
   ```bash
   # Via Proxmox console
   sudo cat /var/log/cloud-init-output.log | tail -20
   ```

### Terraform plan shows unexpected changes

This can happen if:
1. Resources were modified outside Terraform
2. The Terraform state is out of sync with reality

Run `tofu plan` and review the output carefully before `tofu apply`.

### workflow_dispatch not available

If you don't see the **Run workflow** button:
1. Ensure you are on the `main` branch in the UI
2. Ensure the workflow file has `workflow_dispatch:` in its `on:` section
3. Wait a few minutes after pushing the workflow file — GitHub needs to index it

---

## Secrets Flow Summary

```mermaid
graph TD
    bw["Bitwarden Secrets Manager"] -->|"pulled via BW_ACCESS_TOKEN"| runner["GitHub Actions Runner<br/><br/>PM_API_TOKEN_ID<br/>PM_API_TOKEN_SECRET<br/>CLOUDFLARE_API_TOKEN<br/>TAILSCALE_OAUTH_CLIENT_ID<br/>TAILSCALE_OAUTH_CLIENT_SECRET<br/>AWS_ACCESS_KEY_ID<br/>AWS_SECRET_ACCESS_KEY<br/>... etc."]
    runner -->|"authenticates to"| tf["OpenTofu/Terraform<br/>• S3 state backend (AWS)<br/>• Proxmox (PM_API_TOKEN)<br/>• Cloudflare (API token)<br/>• Tailscale (API key)"]
    runner -->|"SSH over Tailscale"| ansible["Ansible<br/>• Configure k3s nodes<br/>• Deploy services"]
```
