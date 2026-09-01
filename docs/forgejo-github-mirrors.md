# Forgejo ↔ GitHub Repository Mirrors

This guide covers the practical ways to mirror GitHub repositories into Forgejo at `https://git.chronobyte.net`, plus the extra secret setup needed if you want the mirrored repo to run Forgejo Actions workflows.

---

## 1. What Mirroring Means

Forgejo supports two mirroring models:

- **Pull mirror (GitHub → Forgejo):** Forgejo periodically fetches from GitHub and keeps the mirrored repo up to date.
- **Push mirror (Forgejo → GitHub):** Forgejo pushes changes outward to another remote, usually when Forgejo is the canonical source.

For most homelab use cases, a **pull mirror from GitHub** is the easiest option. The repository stays in sync automatically on a configurable interval, and once the Forgejo runner is deployed, workflows in `.forgejo/workflows/` can run against the mirrored repository.

---

## 2. Method 1: Migrate / Mirror via the Forgejo UI

This is the easiest path when you only need to mirror one repository at a time.

### Step-by-step

1. Log in to Forgejo at `https://git.chronobyte.net`.
2. In the top-right corner, click **+**.
3. Select **New Migration**.
4. Choose **GitHub** as the source.
5. Fill in the repository details:
   - **Clone URL**: `https://github.com/<owner>/<repo>.git`
   - **Repository Name**: choose the destination name in Forgejo
   - **Owner**: select your Forgejo user or organization
6. Enable **This repo will be a mirror**.
7. Set the sync interval:
   - **Default:** 8 hours
   - **Minimum:** 10 minutes
8. If the GitHub repository is private, add authentication:
   - Generate a **GitHub Personal Access Token (classic)**
   - Grant **`repo`** scope
   - Paste the token into the migration form
9. If the GitHub repository is public, leave authentication blank.
10. Click **Migrate Repository**.

### Screenshot-style walkthrough

- **Forgejo UI → + → New Migration**
- **Migration Source → GitHub**
- **Clone URL → `https://github.com/hexabyte8/<repo>.git`**
- **Mirror toggle → enabled**
- **Authentication → GitHub PAT for private repos only**
- **Sync interval → choose 10 min to 8 h**
- **Create → wait for initial clone to finish**

### Notes

- Pull mirroring is enough for most repos; you do **not** need GitHub webhooks just to keep Forgejo updated.
- If a migration fails, re-check the GitHub PAT scope and whether the source repo is private.

---

## 3. Method 2: Forgejo API (Bulk Mirror All GitHub Repos)

Use this when you want to mirror many repositories into Forgejo in one pass.

### What you need

- A **Forgejo API token** from `Forgejo → Settings → Applications → Generate New Token`
- A **GitHub PAT (classic)** with `repo` scope for private repositories
- The `gh` CLI authenticated to GitHub

### Example bulk-mirror script

```bash
#!/usr/bin/env bash
set -euo pipefail

FORGEJO_URL="https://git.chronobyte.net"
FORGEJO_OWNER="hexabyte8"
FORGEJO_TOKEN="REPLACE_ME_FORGEJO_TOKEN"
GITHUB_PAT="REPLACE_ME_GITHUB_PAT"
SYNC_INTERVAL="8h"

gh repo list hexabyte8 --limit 200 --json name,url,isPrivate --jq '.[] | @base64' |
while IFS= read -r row; do
  decode() {
    printf '%s' "$row" | base64 -d | jq -r "$1"
  }

  REPO_NAME=$(decode '.name')
  REPO_URL=$(decode '.url')
  IS_PRIVATE=$(decode '.isPrivate')

  echo "Creating Forgejo mirror for ${REPO_NAME}..."

  curl -fsS \
    -X POST \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGEJO_URL}/api/v1/repos/migrate" \
    -d @- <<JSON
{
  "clone_addr": "${REPO_URL}.git",
  "repo_name": "${REPO_NAME}",
  "repo_owner": "${FORGEJO_OWNER}",
  "mirror": true,
  "mirror_interval": "${SYNC_INTERVAL}",
  "private": ${IS_PRIVATE},
  "auth_username": "hexabyte8",
  "auth_password": "${GITHUB_PAT}"
}
JSON

done
```

### How it works

- `gh repo list` enumerates GitHub repositories.
- Forgejo’s `POST /api/v1/repos/migrate` API creates each mirrored repository.
- `mirror: true` makes the imported repository a pull mirror.
- `mirror_interval` controls how often Forgejo refreshes from GitHub.

### GitHub PAT guidance

- **Public repos only:** PAT can be omitted if you also omit `auth_username` / `auth_password`.
- **Private repos:** use a **classic PAT** with `repo` scope.

### Forgejo token guidance

Create the token in:

- **Forgejo → Settings → Applications → Generate New Token**

Grant repo-management permissions appropriate for the target owner/org.

---

## 4. Method 3: Push Mirror from GitHub to Forgejo

For this homelab, **GitHub webhooks are not required** just to keep Forgejo updated. A Forgejo **pull mirror** is usually sufficient.

If you want **Forgejo to be the canonical source** and push changes to GitHub instead:

1. Open the Forgejo repository.
2. Go to **Settings**.
3. Open **Mirror Settings** (or the relevant **Git Hooks / Push Mirrors** section, depending on UI version).
4. Add a push mirror pointing to:
   - `https://github.com/hexabyte8/<repo>.git`
5. Authenticate with a GitHub PAT that has `repo` scope.

That gives you a **Forgejo → GitHub** push mirror, which is the inverse of the usual GitHub → Forgejo pull-mirror setup.

---

## 5. Required Forgejo Secrets for Actions Workflows

When using Forgejo as a CI runner, configure these secrets at the organization or repository level in Forgejo under **Settings → Secrets**:

```text
TAILSCALE_OAUTH_CLIENT_ID
TAILSCALE_OAUTH_CLIENT_SECRET
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
ADMIN_EMAIL
AUTHENTIK_API_TOKEN
CLOUDFLARE_ACCOUNT_ID
CLOUDFLARE_API_TOKEN
CLOUDFLARE_ZONE_ID
CLOUDFLARE_ZONE_NAME
DEFAULT_VM_PASSWORD
PEER_PUBLIC_IP
PM_API_TOKEN_ID
PM_API_TOKEN_SECRET
PUBLIC_IP
BWS_ACCESS_TOKEN
CLOUDFLARE_TUNNEL_TOKEN
AUTHENTIK_SMTP_PASSWORD
MINECRAFT_RCON_PASSWORD
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
ACTUAL_OPENID_CLIENT_SECRET
FORGEJO_OIDC_CLIENT_SECRET
```

These values should match the same secret values already stored in Bitwarden.

### Where to add org-level secrets in Forgejo

- **Forgejo Admin → Organizations → Settings → Secrets**

If a workflow is repo-specific, repo-level secrets also work.

### Compatibility note

The Forgejo OpenTofu mirrors preserve the reusable-workflow secret interface from GitHub Actions. If you keep that interface unchanged, also define `BW_ACCESS_TOKEN` for compatibility, even though the Forgejo mirrors read most values directly from `secrets.*` instead of using `bitwarden/sm-action`.

---

## 6. Keeping Mirrors in Sync with Workflows

Once the `forgejo-runner` workload is deployed to the cluster, mirrored repositories can run the workflows stored in `.forgejo/workflows/` automatically.

In practice, the flow becomes:

1. Push to GitHub
2. Forgejo pull mirror syncs the repo
3. Forgejo detects workflow files in `.forgejo/workflows/`
4. The self-hosted Forgejo runner executes the workflow

That gives you a GitHub-hosted source repo with Forgejo-hosted CI execution.
