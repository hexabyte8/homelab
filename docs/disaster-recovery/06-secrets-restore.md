# Phase 6: Secrets Restore

> **Time estimate:** ~20–25 minutes
>
> **What this does:** Applies credentials that cannot be stored in the GitHub repository
> (because they are secrets) and must be manually injected after Flux bootstrap.

---

## Why Are Secrets Handled Separately?

Flux syncs everything from the GitHub repository to the cluster. However, real secrets
(API keys, OAuth credentials) cannot be stored in a public or even private git repository
without risk. If the repository is ever compromised or accidentally made public, those
credentials would be exposed.

The solution: store **placeholder values** in git, annotate the Secret with
`kustomize.toolkit.fluxcd.io/reconcile: disabled`, and replace them with real values
manually after each deployment. Flux will skip reconciling annotated secrets and will
not overwrite them.

## Secrets Quick Reference

All secrets are stored in Bitwarden. This table lists every secret that must be patched after a fresh deploy:

| # | Secret Name | Namespace | Bitwarden Entry | Section |
|---|-------------|-----------|-----------------|---------|
| 1 | `operator-oauth` | `tailscale` | "Tailscale Operator OAuth" | [6.1](#61-tailscale-operator-oauth-secret) |
| 2 | `cloudflared-tunnel-credentials` | `cloudflared` | "Cloudflare Tunnel Token" | [6.2](#62-cloudflare-tunnel-token) |
| 3 | `authentik-credentials` | `authentik` | "Authentik Credentials" | [6.3](#63-authentik-credentials) |
| 4 | `authentik-credentials` | `authentik` | "Stalwart noreply SMTP password" | [6.3](#63-authentik-credentials) (smtp-password key) |
| 5 | `stalwart-secrets` | `stalwart` | "Stalwart Admin Password" + "Resend API Key" | [6.4](#64-stalwart-email-server) |

---

## 6.1 Tailscale Operator OAuth Secret

The Tailscale Kubernetes operator needs OAuth credentials to create and manage Tailscale
devices on behalf of your tailnet. Without this, the operator cannot:
- Expose Kubernetes services via Tailscale
- Provision Tailscale ingress hostnames for cluster services

**What is the Tailscale operator?**  
The Tailscale Kubernetes operator is a controller that runs inside k3s and watches for
Kubernetes services and ingresses annotated with Tailscale settings. When it sees one,
it automatically creates a Tailscale device that proxies traffic to that service.

**Retrieve from Bitwarden:**
- "Tailscale Operator OAuth Client ID"
- "Tailscale Operator OAuth Client Secret"

```bash
ssh ubuntu@k3s-server.tailnet.ts.net

# Base64-encode the values
# Replace the placeholder values with the real ones from Bitwarden
CLIENT_ID_B64=$(echo -n "<operator-client-id-from-bitwarden>" | base64)
CLIENT_SECRET_B64=$(echo -n "<operator-client-secret-from-bitwarden>" | base64)

# Patch the secret (replace the REPLACE_ME placeholders with real values)
sudo kubectl patch secret operator-oauth \
  -n tailscale \
  --type='json' \
  -p="[
    {\"op\":\"replace\",\"path\":\"/data/client_id\",\"value\":\"${CLIENT_ID_B64}\"},
    {\"op\":\"replace\",\"path\":\"/data/client_secret\",\"value\":\"${CLIENT_SECRET_B64}\"}
  ]"
```

**Verify the operator picks up the credentials:**
```bash
sudo kubectl -n tailscale get pods
# All pods should show Running

sudo kubectl -n tailscale logs -l app=operator --tail=30
# Look for: "logged in" or "connected to control" or "reconciling"
# You should NOT see authentication errors
```

**What happens next:**
- The Tailscale operator restarts and connects to the tailnet using the OAuth credentials
- It begins processing any Tailscale-annotated services and ingresses in the cluster
- Tailscale ingress devices will appear in the Tailscale admin console within a few minutes

**Reference:** [Tailscale Kubernetes Operator docs](https://tailscale.com/kb/1236/kubernetes-operator)

---

## 6.2 Cloudflare Tunnel Token

The `cloudflared` deployment connects to Cloudflare's edge network and exposes internal
services at `*.example.com`. Without the tunnel token, no public-facing services
(`mail.example.com`, `status.example.com`, etc.) will work.

**Retrieve from Bitwarden:** "Cloudflare Tunnel Token"

If the token is not in Bitwarden, retrieve it from the Cloudflare dashboard:
1. Go to [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → Zero Trust → Networks → Tunnels
2. Click the `homelab` tunnel → Configure → click the **Docker** tab
3. Copy the token value from the `--token` argument

```bash
# The token must be base64-encoded when stored in the Kubernetes Secret
kubectl patch secret cloudflared-tunnel-credentials -n cloudflared \
  --type='merge' \
  -p="{\"data\":{\"tunnel-token\":\"$(echo -n '<tunnel-token-from-bitwarden>' | base64 -w0)\"}}"
```

**Verify cloudflared connects:**
```bash
kubectl rollout restart deployment/cloudflared -n cloudflared
kubectl rollout status deployment/cloudflared -n cloudflared

kubectl logs -n cloudflared deployment/cloudflared --since=2m | grep -E "connect|tunnel|error|registered"
# Look for: "Connection registered" or "Connected to Cloudflare"
```

**Test a public endpoint** (from outside the tailnet):
```bash
curl -I https://status.example.com
# Should return HTTP 200 or a redirect — not a connection refused or tunnel error
```

---

## 6.3 Authentik Credentials

Authentik is the SSO/identity provider. It needs three secrets:
- `secret-key` — cryptographic signing key for sessions/tokens (must be stable across restarts)
- `bootstrap-password` — initial `akadmin` user password
- `smtp-password` — password for the `noreply` Stalwart account (for sending emails)

**Retrieve from Bitwarden:** "Authentik Credentials"

```bash
# Patch all three keys at once
kubectl patch secret authentik-credentials -n authentik --type=merge \
  -p "{\"stringData\":{
    \"secret-key\": \"<secret-key-from-bitwarden>\",
    \"bootstrap-password\": \"<akadmin-password-from-bitwarden>\",
    \"smtp-password\": \"<stalwart-noreply-password-from-bitwarden>\"
  }}"
```

!!! warning "secret-key must stay consistent"
    If the `secret-key` changes, all existing Authentik sessions are invalidated and
    users must log in again. OAuth tokens issued to applications may also be invalidated.
    Always restore the same key from Bitwarden — do not generate a new one unless you
    understand the consequences.

**Restart Authentik to pick up the new secrets:**
```bash
kubectl rollout restart deployment/authentik-server deployment/authentik-worker -n authentik
kubectl rollout status deployment/authentik-server -n authentik
```

**Verify Authentik starts:**
```bash
kubectl logs -n authentik deployment/authentik-server --since=2m | grep -E "startup|error|Error" | tail -10
# Should not show database or secret-related errors
```

**Log in to Authentik:**
- URL: `https://authentik.tailnet.ts.net`
- Username: `akadmin`
- Password: the `bootstrap-password` you just patched

### Post-Restore: Authentik OpenTofu Configuration

All Authentik configuration (flows, providers, applications, outposts, LDAP) is managed
by **OpenTofu** in `opentofu/authentik*.tf`. After a fresh restore, run `tofu apply` via
GitHub Actions to re-provision all Authentik resources:

```
Actions → OpenTofu Apply → Run workflow
```

This will create the recovery flow, invitation flow, LDAP outpost, ForwardAuth provider
for docs, and the `family&friends` group.

**Verify the recovery flow exists** (critical for password reset):
```bash
kubectl exec -n authentik deployment/authentik-server -- \
  ak shell -c "from authentik.flows.models import Flow; print(list(Flow.objects.filter(slug='default-recovery-flow').values('slug','name')))"
# Expected: [{'slug': 'default-recovery-flow', 'name': 'default-recovery-flow'}]
```

!!! note "What OpenTofu cannot configure"
    Outpost application assignments and user/group memberships must be re-done in the
    Authentik UI after a restore. See `docs/authentik.md` for details.

---

## 6.4 Stalwart Email Server

Stalwart needs two secrets: the admin password and the Resend API key for outbound relay.

**Retrieve from Bitwarden:** "Stalwart Admin Password" and "Resend API Key"

```bash
kubectl patch secret stalwart-secrets -n stalwart --type=merge \
  -p '{"stringData":{"admin-password":"<password-from-bitwarden>","resend-api-key":"re_..."}}'

kubectl rollout restart deployment/stalwart -n stalwart
kubectl rollout status deployment/stalwart -n stalwart
```

**Recreate service email accounts (if PVC was wiped):**

Stalwart stores accounts in RocksDB on the PVC. If the PVC survived the rebuild, accounts
are already there. If the PVC was wiped:

1. Log into `https://mail.tailnet.ts.net` with `admin` / the password you just patched
2. **Directory → Accounts → New Account**: create `noreply@example.com`
3. Set the password — this must match what is in `smtp-password` in the `authentik-credentials` secret

**Verify Cloudflare Email Routing is still active:**

After `tofu apply` runs, Cloudflare Email Routing should already be enabled. If you see
inbound mail not being forwarded to Gmail, check:
1. [Cloudflare dashboard → Email → Email Routing](https://dash.cloudflare.com) → verify it shows **Enabled**
2. The destination address (`admin@example.com`) shows as **Verified** — if not, re-trigger verification from the dashboard

**Test outbound email:**
```bash
kubectl exec -n authentik deployment/authentik-worker -- ak test_email admin@example.com 2>&1 | \
  grep -E "email_sent|error" | tail -3
# Should show: "message": "Email to admin@example.com sent"
```

---

## 6.5 Deploy Game Server Services (Optional)

If you also want to restore the Minecraft game server:

### Install S3 Backup Service

```bash
# Via GitHub Actions:
# Actions → Ansible - Deploy S3 Backup → Run workflow
# Inputs:
#   target_host: game-server
#   backup_schedule: "0 4 * * *"  (4 AM daily)
```

This installs:
- AWS CLI v2 on the game server
- A backup script that tarballs the Minecraft world and uploads to S3
- A systemd service and timer for scheduled backups

### Deploy Minecraft Service

```bash
# Via GitHub Actions:
# Actions → Ansible - Deploy Minecraft → Run workflow
# Input:
#   target_host: game-server
```

This creates and enables a systemd service for the Minecraft server.

---

## Summary Checklist

Before proceeding to Phase 7:

- [ ] `operator-oauth` secret patched with real Tailscale OAuth credentials
- [ ] Tailscale operator pods show `Running` status
- [ ] Tailscale operator logs show successful authentication (no errors)
- [ ] Tailscale ingress devices appearing in Tailscale admin console
- [ ] `cloudflared-tunnel-credentials` secret patched with real tunnel token
- [ ] cloudflared pod running and connected (`Connected to Cloudflare` in logs)
- [ ] `authentik-credentials` patched with `secret-key`, `bootstrap-password`, `smtp-password`
- [ ] Authentik accessible at `https://authentik.tailnet.ts.net`
- [ ] OpenTofu Applied — Authentik flows, providers, and LDAP outpost provisioned
- [ ] Recovery flow `default-recovery-flow` exists in Authentik
- [ ] `stalwart-secrets` patched with admin password and Resend API key
- [ ] Stalwart `noreply@example.com` account exists (or recreated)
- [ ] Test email sends successfully via `ak test_email`
- [ ] (Optional) Game server services restored

---

## Proceed to Phase 7

→ [Phase 7: Validation](./07-validation.md)
