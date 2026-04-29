# Bitwarden — Technology Guide

> This guide explains what Bitwarden is and how it is used as the central secrets
> management system for this homelab.
> No prior password manager experience required.

---

## What is Bitwarden?

**Bitwarden** is an open-source **password and secrets manager**. In this homelab,
it serves as the **single source of truth** for all credentials, API keys, and
sensitive values.

**Why centralized secrets management?**

Without a secrets manager, you might:
- Store passwords in a text file (insecure)
- Hardcode credentials in scripts (catastrophic if the repo is ever public)
- Forget where you stored a credential
- Lose credentials when hardware fails

With Bitwarden:
- All credentials are encrypted and stored in the cloud
- Access from any device (web vault, mobile app, browser extension)
- Survives complete hardware failure
- Audit log of all accesses (paid tier)
- Bitwarden Secrets Manager for machine-to-machine secrets (GitHub Actions)

**References:**
- [Bitwarden official documentation](https://bitwarden.com/help/)
- [Bitwarden web vault](https://vault.bitwarden.com)
- [Bitwarden Secrets Manager documentation](https://bitwarden.com/help/secrets-manager-overview/)

---

## Two Separate Products Used

This homelab uses **two Bitwarden products**:

### 1. Bitwarden Password Manager

The **consumer password manager** — used for storing human-readable credentials
that you access manually.

**Access at:** [vault.bitwarden.com](https://vault.bitwarden.com)

Used to store:
- API tokens (Cloudflare, Tailscale, AWS)
- VM passwords
- SSH private keys
- Tailscale OAuth credentials

**Use during disaster recovery:**  
Log in to the web vault and copy credentials as needed.

### 2. Bitwarden Secrets Manager

A **machine-to-machine secrets management** service — used for storing secrets
that are loaded by GitHub Actions workflows at runtime.

**Access at:** [sm.bitwarden.com](https://sm.bitwarden.com)

Used to store:
- All secrets used by GitHub Actions workflows
- Secrets are referenced by UUID, not by name
- Access is controlled by **Service Accounts** (machine identities)

**Key concept:** Each GitHub Actions workflow uses `bitwarden/sm-action@v3` to pull
secrets from Bitwarden SM at the start of the run. The only credential GitHub needs
to know is `BW_ACCESS_TOKEN` (a service account token).

---

## How GitHub Actions Uses Bitwarden SM

Every GitHub Actions workflow in this homelab follows this pattern:

```yaml
# Step 1: Pull secrets from Bitwarden Secrets Manager
- name: Get Secrets
  uses: bitwarden/sm-action@v3
  with:
    access_token: ${{ secrets.BW_ACCESS_TOKEN }}
    secrets: |
      <UUID_1> > ENV_VAR_NAME_1
      <UUID_2> > ENV_VAR_NAME_2
      <UUID_3> > ENV_VAR_NAME_3

# Step 2: Use the secrets in subsequent steps
- name: Do Something
  env:
    MY_SECRET: ${{ env.ENV_VAR_NAME_1 }}
  run: |
    echo "Secret is available as $MY_SECRET"
```

**How it works:**
1. The workflow starts with only `BW_ACCESS_TOKEN` (a GitHub Actions repository secret)
2. `bitwarden/sm-action` uses the token to authenticate to Bitwarden SM
3. It fetches each secret by UUID and sets it as an environment variable
4. Subsequent steps can use these secrets as `${{ env.VAR_NAME }}`
5. GitHub Actions automatically masks these values in logs (shows `***`)

**Reference:** [bitwarden/sm-action on GitHub Marketplace](https://github.com/marketplace/actions/bitwarden-secrets-manager-github-action)

---

## Setting Up BW_ACCESS_TOKEN

`BW_ACCESS_TOKEN` is the single credential that enables all workflows. It must be
set as a GitHub Actions **repository secret** (not in Bitwarden SM itself — it's the
key that unlocks everything else).

### Getting the Token

1. Log in to [sm.bitwarden.com](https://sm.bitwarden.com)
2. Navigate to your organization → **Service Accounts**
3. Find the service account used by GitHub Actions
4. Under **Access Tokens**, create a new token (or find an existing one if it hasn't expired)
5. Copy the token value

### Setting the GitHub Secret

1. Go to your repository: [github.com/hexabyte8/homelab](https://github.com/hexabyte8/homelab)
2. Navigate to **Settings → Secrets and variables → Actions**
3. Click **New repository secret**
4. Name: `BW_ACCESS_TOKEN`
5. Value: paste the token
6. Click **Add secret**

### If the Token Expires

Bitwarden SM access tokens have an optional expiration date. If workflows start failing
with authentication errors:
1. Log in to Bitwarden SM
2. Create a new access token for the service account
3. Update the `BW_ACCESS_TOKEN` GitHub secret with the new value

---

## Organizing Secrets in Bitwarden

### Recommended Bitwarden Vault Structure

Create a folder called `Homelab` in your Bitwarden vault and organize entries:

```
Homelab/
├── Proxmox
│   ├── PM_API_TOKEN_ID
│   ├── PM_API_TOKEN_SECRET
│   └── DEFAULT_VM_PASSWORD
├── Cloudflare
│   ├── CLOUDFLARE_API_TOKEN
│   ├── CLOUDFLARE_ZONE_ID
│   ├── CLOUDFLARE_ZONE_NAME
│   └── CLOUDFLARE_ACCOUNT_ID
├── AWS
│   ├── AWS_ACCESS_KEY_ID
│   ├── AWS_SECRET_ACCESS_KEY
│   └── S3_BACKUP_BUCKET_NAME
├── Tailscale
│   ├── TAILSCALE_API_KEY
│   ├── TAILSCALE_OAUTH_CLIENT_ID (CI)
│   ├── TAILSCALE_OAUTH_CLIENT_SECRET (CI)
│   ├── Tailscale Operator OAuth Client ID
│   └── Tailscale Operator OAuth Client Secret
├── SSH Keys
│   ├── Flux SSH Deploy Key (Private)
│   └── Flux SSH Deploy Key (Public)
└── GitHub
    └── BW_ACCESS_TOKEN (note: also set as GitHub Secret)
```

### Bitwarden Secrets Manager Structure

In Bitwarden SM, secrets are organized by project:

```
Projects/
└── homelab/
    ├── PM_API_TOKEN_ID
    ├── PM_API_TOKEN_SECRET
    ├── CLOUDFLARE_API_TOKEN
    ├── CLOUDFLARE_ZONE_ID
    ├── CLOUDFLARE_ACCOUNT_ID
    ├── CLOUDFLARE_ZONE_NAME
    ├── AWS_ACCESS_KEY_ID
    ├── AWS_SECRET_ACCESS_KEY
    ├── S3_BACKUP_BUCKET_NAME
    ├── TAILSCALE_OAUTH_CLIENT_ID
    ├── TAILSCALE_OAUTH_CLIENT_SECRET
    └── ... (other secrets used by workflows)
```

---

## Security Best Practices

1. **Enable two-factor authentication (2FA)** on your Bitwarden account
   - Without 2FA, anyone with your master password can access all homelab credentials
   - Use an authenticator app (not SMS)

2. **Use a strong master password** — Bitwarden encrypts everything with this password
   - If you forget it, your vault is unrecoverable (Bitwarden cannot reset it for you)

3. **Store the master password safely** — consider writing it down and storing it in
   a physically secure location (safe, safety deposit box)

4. **Export the vault periodically** — make an encrypted export for offline backup:
   - Bitwarden → Tools → Export vault → Encrypted JSON

5. **Review connected devices** — check that only your devices are authorized:
   - Bitwarden vault → Settings → Active sessions

---

## Common Troubleshooting

### Workflow fails with "Bitwarden SM authentication failed"

The `BW_ACCESS_TOKEN` is expired or invalid:
1. Log in to Bitwarden SM
2. Create a new access token
3. Update the GitHub `BW_ACCESS_TOKEN` secret

### Can't find a secret UUID

Secrets in Bitwarden SM are referenced by UUID in workflow files. To find a UUID:
1. Log in to Bitwarden SM
2. Find the secret in your project
3. The UUID is shown in the secret's detail view (or in the URL)

### Lost access to Bitwarden account

1. Check if you have emergency access set up with a trusted person
2. Try recovery codes if you have 2FA enabled
3. Contact Bitwarden support at [bitwarden.com/contact](https://bitwarden.com/contact)

> ⚠️ **Important:** If you lose access to your Bitwarden vault, disaster recovery
> becomes impossible. Ensure you have recovery options set up and your master password
> is backed up safely.
