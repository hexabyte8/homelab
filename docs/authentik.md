# Authentik SSO

This document covers the Authentik deployment in the homelab k3s cluster — what it provides, how it's set up, and how to protect services with ForwardAuth.

---

## Overview

[Authentik](https://goauthentik.io/) is the identity provider (IdP) for the homelab cluster. It provides:

- **SSO** — single sign-on across all protected services
- **OIDC / OAuth2** — for apps that support standards-based authentication
- **LDAP** — for apps that only speak LDAP (via built-in LDAP outpost)
- **ForwardAuth** — proxy-level authentication via Traefik, so services without any auth support can be gated behind a login page

Authentik is accessible at **<https://authentik.tailnet.ts.net>**.

---

## Architecture

| Component | Detail |
|---|---|
| **PostgreSQL** | CNPG cluster `authentik-db` in the `authentik` namespace |
| **Redis** | Authentik's built-in Redis (bundled in the Helm chart) |
| **TLS** | cert-manager with ClusterIssuer `letsencrypt-production` |
| **Ingress** | Tailscale Funnel at `authentik.tailnet.ts.net` |
| **Credentials secret** | `authentik-credentials` (must be patched after deploy — see below) |
| **ForwardAuth middleware** | `authentik-forward-auth` in namespace `authentik` |

Flux manages the deployment via a `HelmRelease` in `k3s/flux/apps/authentik.yaml`. Once the HelmRelease reconciles, a few manual post-deploy steps are required before Authentik is usable.

---

## Flows as Code (OpenTofu)

All Authentik flows, stages, providers, applications and outpost membership in this homelab
are managed declaratively using the **goauthentik/authentik OpenTofu provider**. The Terraform
state lives alongside the rest of the homelab IaC in S3 (`opentofu/` directory).

Key files:

| File | Contents |
|---|---|
| `opentofu/main.tf` | Provider block (`provider "authentik" {}`) |
| `opentofu/authentik.tf` | Embedded outpost adoption, ForwardAuth proxy provider (docs), the `family&friends` group |
| `opentofu/authentik-recovery.tf` | Password-reset flow + brand `flow_recovery` wiring |
| `opentofu/authentik-enrollment.tf` | Invitation-based enrollment flow → `family&friends` |
| `opentofu/authentik-ldap.tf` | LDAP provider, dedicated bind flow, LDAP outpost, Jellyfin service-account user |

The provider authenticates with `AUTHENTIK_API_TOKEN` (Bitwarden Secrets Manager UUID
`73f4bb30-0c41-445c-908e-b43a00ef7863`). Both `opentofu-plan.yml` and `opentofu-apply.yml` workflows
inject it. Pushing to `main` runs `tofu apply` automatically.

The previous YAML-blueprint approach (`k3s/manifests/authentik/blueprints-configmap.yaml`) has been
removed — all blueprint state should be ported to OpenTofu instead. UI changes that aren't reflected
in TF will be reverted on the next apply.

> **Adding a new ForwardAuth-protected app:** add an `authentik_provider_proxy` + `authentik_application`,
> append the provider's id to `authentik_outpost.embedded.protocol_providers`, then add the
> middleware chain `kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd`
> to the Kubernetes `Ingress`.

---

## Password Recovery

The recovery flow (slug `default-recovery-flow`) is wired into the default Brand and into the
`default-authentication-identification` stage, so:

- The "Forgot password?" link on the main login page redirects through it.
- Admin → Send recovery email also uses it.

The flow's email stage uses Authentik's **global SMTP settings** (configured on the HelmRelease in
`k3s/flux/apps/authentik.yaml`) which point at Stalwart at `stalwart.stalwart.svc.cluster.local:587`,
sender `noreply@example.com`. The SMTP password lives in the `authentik-credentials` secret
(key `smtp-password`, BWS UUID `793deec1-de4b-487b-b685-b43a00e06099`).

Test it: visit the login page → "Forgot password?" → enter username/email → an email lands at the
user's inbox with a 30-minute reset link.

---

## Onboarding New Users (Invitation Flow)

User self-registration is **gated by an invitation token** (Authentik's `invitation` stage with
`continue_flow_without_invitation = false`). Anyone enrolled via this flow is automatically added
to the **`family&friends`** group.

### Automated invite via GitHub Actions (preferred)

The easiest way to invite someone is via the **Authentik Invite** workflow:

1. Go to **Actions → Authentik Invite → Run workflow** in the GitHub repository.
2. Enter the recipient's email address in the `email` input.
3. Click **Run workflow**.

The workflow (`authentik-invite.yml`) calls Authentik's
`/api/v3/stages/invitation/invitations/` API to create a single-use invitation bound to
the `default-invitation-enrollment` flow, then emails the invite link to the recipient via
the **Resend API** (using `STALWART_RESEND_API_KEY` from Bitwarden). The invitation
expires after the default configured lifetime.

The recipient receives an email with a link like:
```
https://authentik.tailnet.ts.net/if/flow/default-invitation-enrollment/?itoken=<uuid>
```
They click it, choose a username/display name/password, and are immediately logged in as a
member of `family&friends`. If they visit the flow URL without a valid token, they see a
"denied" screen.

### Manual invite via Authentik UI

1. Go to **Directory → Tokens & App passwords → Invitations** in the Authentik admin UI.
2. Click **Create**, pick flow `default-invitation-enrollment`, set an expiry, and (optionally)
   pre-fill `username` / `email` in the fixed-data JSON.
3. Copy the invite URL and send it to the recipient manually.

---

## LDAP Outpost (for Jellyfin and other LDAP-only clients)

Authentik runs a dedicated **LDAP outpost** (TF: `authentik_outpost.ldap`) deployed by Authentik
itself into the `authentik` namespace via the local Kubernetes service connection. It exposes
users over LDAP for clients that can't speak OIDC.

| Setting | Value |
|---|---|
| LDAP service | `ak-outpost-ldap-outpost.authentik.svc.cluster.local` |
| Port (plain) | `389` |
| Port (TLS, self-signed) | `636` |
| Base DN | `dc=chronobyte,dc=net` |
| Bind flow | `ldap-bind-flow` (no MFA, dedicated; clones identification + login only) |
| Bind user (Jellyfin) | `cn=jellyfin-ldap-bind,ou=users,dc=chronobyte,dc=net` |

The Jellyfin LDAP plugin should be configured roughly as:

```text
LDAP server:        ak-outpost-ldap-outpost.authentik.svc.cluster.local
LDAP port:          389
Use SSL/TLS:        unchecked (in-cluster traffic)
Bind user:          cn=jellyfin-ldap-bind,ou=users,dc=chronobyte,dc=net
Bind password:      <password set on the authentik_user.jellyfin_ldap_bind via the admin UI>
User search base:   ou=users,dc=chronobyte,dc=net
User filter:        (&(objectClass=user)(memberOf=cn=family&friends,ou=groups,dc=chronobyte,dc=net))
Username attribute: cn
```

The bind user (`jellyfin-ldap-bind`) is a service-account user created by Terraform. Its password
must be **set once via the Authentik admin UI** (Directory → Users → jellyfin-ldap-bind →
Set password) — Terraform does not manage the password, only the user record. Save the password
in Bitwarden as `JELLYFIN_LDAP_BIND_PASSWORD`.

> **Note:** The user filter limits Jellyfin logins to members of the `family&friends` group. If
> you want broader access, drop the `memberOf` clause from the filter.

---


## Post-Deploy Setup

### 1. Patch the secret key

The `authentik-credentials` secret is committed to git with a placeholder value. Patch it with a real random key before starting Authentik:

```bash
kubectl -n authentik patch secret authentik-credentials \
  --type='json' -p='[{"op":"replace","path":"/data/secret-key","value":"'"$(openssl rand -base64 60 | tr -d '\n' | base64)"'"}]'
```

> **Why `kubectl patch`?** Flux uses Server-Side Apply (SSA), so `kubectl apply` will conflict. Always use `kubectl patch` for secrets managed this way. See [gitops-flux.md](gitops-flux.md#patched-secrets) — *Patched Secrets*.

### 2. Wait for the CNPG cluster

Authentik's server pod won't become healthy until the PostgreSQL cluster is ready:

```bash
kubectl get cluster -n authentik authentik-db
# Wait until READY is True and STATUS is Cluster in healthy state
```

### 3. Log in with bootstrap credentials

The `/if/flow/initial-setup/` wizard was removed in Authentik 2023.3+. Instead, bootstrap credentials are injected at first startup via environment variables.

Before pushing (or after Flux creates the secret), patch the bootstrap password into the secret:

```bash
kubectl -n authentik patch secret authentik-credentials \
  --type='json' -p='[{"op":"replace","path":"/data/bootstrap-password","value":"'$(echo -n 'YourChosenPassword' | base64)'"}]'
```

Then log in directly at **<https://authentik.tailnet.ts.net>** with:
- **Username**: `akadmin`
- **Password**: the bootstrap password you set above

> The bootstrap credentials only take effect on first startup (before any admin user exists). Store them in your password manager and change the password after first login.


---

## Protecting a Service with ForwardAuth

The `authentik-forward-auth` Traefik Middleware is already deployed in the `authentik` namespace. Reference it in any Ingress or IngressRoute to require authentication.

### Standard Kubernetes Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myservice
  namespace: myservice
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: >-
      kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  rules:
    - host: myservice.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myservice
                port:
                  number: 80
  tls:
    - hosts:
        - myservice.example.com
      secretName: myservice-tls
```

!!! note "Middleware reference format"
    Traefik middleware references follow `<namespace>-<name>@kubernetescrd`. Because the middleware lives in the `authentik` namespace and is named `authentik-forward-auth`, the full reference is:

    ```
    authentik-authentik-forward-auth@kubernetescrd
    ```

!!! warning "Cloudflare Tunnel requires an additional middleware"
    When traffic arrives via Cloudflare Tunnel, chain `kube-system-cloudflare-https-scheme@kubernetescrd` **before** the ForwardAuth middleware (as shown above). This rewrites `X-Forwarded-Proto` to `https`, which Authentik requires to build a valid OIDC callback URL. Without it, auth will fail with a 400 error on the callback. See [cloudflare-tunnels.md](cloudflare-tunnels.md) for details.

### Traefik IngressRoute CRD

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myservice
  namespace: myservice
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myservice.example.com`)
      kind: Rule
      middlewares:
        - name: authentik-forward-auth
          namespace: authentik
      services:
        - name: myservice
          port: 80
  tls:
    certResolver: letsencrypt-production
```

With IngressRoute, the middleware namespace is specified explicitly so there is no namespace-prefix ambiguity.

---

## ForwardAuth with Services That Have Built-in Auth

Some services (e.g. Uptime Kuma, Grafana, Gitea) ship with their own login page. When you add Authentik ForwardAuth in front of them, users hit **two logins in sequence** — Authentik first, then the service's own login. This is confusing and unnecessary.

### The fix: disable the service's built-in auth

**Preferred: environment variable (DR-resilient)**

Set an env var in the Deployment to tell the service to skip its own login:

```yaml
containers:
  - name: uptime-kuma
    image: louislam/uptime-kuma:1
    env:
      - name: UPTIME_KUMA_DISABLE_AUTH
        value: "1"
```

Common env vars for other services:

| Service | Env var | Value |
|---|---|---|
| Uptime Kuma | `UPTIME_KUMA_DISABLE_AUTH` | `"1"` |
| Grafana | `GF_AUTH_DISABLE_LOGIN_FORM` | `"true"` |
| Grafana (anonymous access) | `GF_AUTH_ANONYMOUS_ENABLED` | `"true"` |

Check each service's documentation for the exact variable name.

> **Why env var and not the UI setting?** Many services allow disabling auth via a UI toggle that is then persisted in the service's data volume. That works fine day-to-day, but after a disaster recovery restore with a fresh PVC the volume is empty — the UI setting is gone and the service's login page reappears. The env var approach is baked into the Deployment manifest (committed to git) and survives any PVC loss.

**Alternative: UI setting**

Some services let you disable auth from within their admin panel (e.g. Grafana → Administration → Authentication). This is faster to set up but only persists in the PVC. Use the env var approach for any service you want to be fully DR-resilient.

### Tailscale backdoor caveat

If the service is **also** exposed via a Tailscale Ingress (as an admin escape hatch), note that Tailscale traffic bypasses Traefik entirely — Authentik ForwardAuth does **not** apply on that path. A tailnet member can reach the service directly without an Authentik session.

This is intentional: it provides a trusted admin backdoor if Authentik is down. But it means that if the service's built-in auth is disabled, the Tailscale URL gives unauthenticated access to any tailnet member. Keep this in mind when deciding whether to disable built-in auth.

---

## OIDC / OAuth2 vs ForwardAuth

When a service natively supports OAuth2/OIDC (e.g. Grafana, Gitea, Nextcloud), **prefer OIDC over ForwardAuth**. OIDC gives the service a proper user identity — it can map Authentik groups to roles, show the user's display name, and log meaningful audit events. ForwardAuth only proves "someone is authenticated" but the service sees an anonymous session.

| | ForwardAuth | OIDC |
|---|---|---|
| Service support required | None — works with any app | App must support OAuth2/OIDC |
| User identity in app | Anonymous | Full (name, email, groups) |
| Role/group mapping | Not possible | Supported via claims |
| Setup complexity | Low | Medium |

Use ForwardAuth for apps with no auth support or where deep integration isn't needed. Use OIDC when the service supports it and you want proper identity propagation.

For OIDC setup steps, see [Setting Up a New Application in Authentik → For OIDC](#for-oidc-apps-with-native-login-support) below.

---

## Setting Up a New Application in Authentik

These steps are required any time you want to protect a new service with ForwardAuth (via Traefik) or OIDC. The process is: create a **Provider** → create an **Application** → assign to the **Outpost**.

### Step 1 — Create a Proxy Provider

1. Go to **Applications → Providers → Create**.
2. Select **Proxy Provider**.
3. Fill in:
   - **Name**: `myapp-proxy` (use the service name for clarity)
   - **Authorization flow**: `default-provider-authorization-implicit-consent`
   - **Mode**: `Forward auth (single application)`
   - **External Host**: `https://myapp.example.com` — must exactly match the public URL users will visit, including scheme (`https://`)
4. Click **Finish**.

> **External Host must be exact.** If users visit `https://myapp.example.com` but the provider has `http://myapp.example.com`, Authentik will reject the auth check and return 401s.

### Step 2 — Create an Application

1. Go to **Applications → Applications → Create**.
2. Fill in:
   - **Name**: `My App` (display name shown on the Authentik portal)
   - **Slug**: `myapp` (URL-safe, lowercase, no spaces)
   - **Provider**: select `myapp-proxy`
   - **Launch URL**: `https://myapp.example.com`
3. Under **Policy / Group / User bindings** (optional): bind a group to restrict access to specific users. Leave empty to allow all authenticated users.
4. Click **Create**.

### Step 3 — Assign to the Embedded Outpost

This is the step most guides gloss over. The embedded outpost is what actually performs the ForwardAuth check — the application must be explicitly assigned to it.

1. Go to **Applications → Outposts**.
2. Find the outpost named **`authentik Embedded Outpost`** (Type: `Proxy`).
3. Click **Edit** (pencil icon).
4. In the **Applications** field, find your new app in the left list and move it to the right (selected) list.
5. Click **Update**.

The outpost updates within ~30 seconds. After that, any request to `https://myapp.example.com` that lacks a valid Authentik session will be redirected to the Authentik login page.

> **Verify it's working:** open an incognito window and visit `https://myapp.example.com`. You should be redirected to `https://authentik.tailnet.ts.net/if/flow/...` before reaching the app.

### For OIDC (apps with native login support)

If the app supports OAuth2/OIDC natively (e.g. Gitea, Grafana), create an **OAuth2/OpenID Connect Provider** instead of a Proxy Provider. See the [OIDC vs ForwardAuth](#oidc--oauth2-vs-forwardauth) section above for when to prefer this approach.

1. Go to **Applications → Providers → Create**.
2. Select **OAuth2/OpenID Connect Provider** and fill in:
   - **Name**: descriptive name (e.g. `myservice-oidc`)
   - **Authorization flow**: `default-provider-authorization-implicit-consent`
   - **Client type**: `Confidential`
   - **Redirect URIs**: the callback URL of your application (check the app's docs — usually `https://myapp.example.com/auth/callback` or similar)
   - **Signing Key**: `authentik Self-signed Certificate`
3. Note the **Client ID** and **Client Secret** — you'll need these in the app's config.
4. Go to **Applications → Applications → Create** and link this provider.
5. OIDC providers do **not** require outpost assignment — the Authentik server handles token exchange directly.

**OIDC discovery URL** (use this in the app's "auto-discover" field if supported):

```
https://authentik.tailnet.ts.net/application/o/<slug>/.well-known/openid-configuration
```

Replace `<slug>` with the application slug you set in step 4 (e.g. `myservice`). The discovery document lists all token endpoints, supported scopes, and the JWKS URI — most OIDC clients can configure themselves from it automatically.

---

## Password Reset / Account Recovery

Users can reset their password via a self-service recovery flow. When they click "Forgot
Password" on the login page, they receive an email with a one-time link. Clicking the link
takes them back to Authentik where they set a new password.

### How It Works

```
User → clicks "Forgot Password" → Recovery Flow:
  Step 1: Email Stage        — sends one-time token to user's email (expires in 30 min)
  Step 2: (user clicks link) — token verified, flow continues
  Step 3: Prompt Stage       — user enters new password + confirmation
  Step 4: User Write Stage   — new password saved to Authentik
```

The flow is managed declaratively via **OpenTofu** in `opentofu/authentik-recovery.tf`.
It creates and wires all stages on every `tofu apply` — no manual Authentik UI configuration
is needed for the recovery flow.

### Flow Components

| Component | Name | Purpose |
|-----------|------|---------|
| Identification Stage | `default-recovery-identification` | Collects username/email at start of flow before sending token (order -10) |
| Email Stage | `default-recovery-email` | Sends the recovery email using global SMTP settings |
| Prompt Stage | `default-recovery-user-write-prompts` | Collects new password + confirmation |
| User Write Stage | `default-recovery-user-write` | Persists the new password |
| Recovery Flow | `default-recovery-flow` | Chains the stages in order |

The email stage uses the global SMTP settings from the Authentik HelmRelease values
(Stalwart on port 587, `noreply@example.com`).

### Triggering a Password Reset

**As a user:**
1. Go to https://authentik.tailnet.ts.net
2. Click **Forgot Password** below the login form
3. Enter your username or email address
4. Check your inbox for the recovery email (check spam if not received within 2 minutes)
5. Click the link in the email — it expires in **30 minutes**
6. Enter and confirm your new password

**As an admin (forcing a password reset):**
```bash
# Trigger recovery flow for a user via the Authentik UI:
# Admin → Directory → Users → <user> → Actions → Recovery link
# Copy the link and send it manually, or use "Send recovery email"
```

### Known Configuration Requirements

Two non-obvious requirements **both** must be satisfied for the admin "Send recovery email" button and the "Forgot Password" login link to work:

1. **Identification Stage must be first** — The recovery flow requires a `default-recovery-identification` IdentificationStage at order=-10 as its first step. Without it, clicking "Forgot Password" without first entering a username results in `"request denied, unknown error"` because the Email Stage has no pending user context.

2. **`Brand.flow_recovery` must be set** — The admin API (`POST /api/v3/core/users/{id}/recovery_email/`) reads the recovery flow from the *Brand* object, not from the flow designation. If `brand.flow_recovery` is `None`, the API returns `400 {"non_field_errors": "No recovery flow set."}` regardless of whether the flow exists.

3. **Flow `authentication` must be `none`** — If set to `require_unauthenticated`, the FlowPlanner rejects the request when an authenticated admin triggers it, returning `400 {"non_field_errors": "Recovery flow not applicable to user"}`. Setting it to `none` allows both unauthenticated (user self-service) and authenticated (admin-initiated) planning.

All three are handled by the OpenTofu config in `opentofu/authentik-recovery.tf`. If you see any of these errors, re-run `tofu apply` or fix manually as below.

### Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| "Forgot Password" link not visible | `Brand.flow_recovery` not set | Run fix below or re-run `tofu apply` |
| "Request has been denied, unknown error" on Forgot Password | No identification stage in recovery flow | Re-run `tofu apply`; or add `default-recovery-identification` IdentificationStage at order=-10 via UI |
| Admin "Send recovery email" → `400 No recovery flow set.` | `Brand.flow_recovery` is `None` | See Brand fix below |
| Admin "Send recovery email" → `400 Recovery flow not applicable to user` | Flow `authentication = require_unauthenticated` | Set flow authentication to `none` (see fix below) |
| Recovery email not received | SMTP misconfigured or Stalwart down | Check Stalwart pod and Resend dashboard |
| "No user found" error | User typed wrong username/email | Try alternate (username vs email); ensure `pretend_user_exists=true` is set |
| Link expired | >30 minutes elapsed | Request a new reset — token expires in 30 minutes |
| Password not saved | User Write Stage not bound | Check FlowStageBindings in Authentik UI or re-run `tofu apply` |

**Fix Brand.flow_recovery manually:**
```bash
kubectl exec -n authentik deployment/authentik-server -- \
  ak shell -c "
from authentik.brands.models import Brand
from authentik.flows.models import Flow
brand = Brand.objects.first()
flow = Flow.objects.get(slug='default-recovery-flow')
brand.flow_recovery = flow
brand.save()
print('Updated:', brand.domain, '->', brand.flow_recovery.slug)
"
```

**Fix flow authentication manually:**
```bash
kubectl exec -n authentik deployment/authentik-server -- \
  ak shell -c "
from authentik.flows.models import Flow, FlowAuthenticationRequirement
flow = Flow.objects.get(slug='default-recovery-flow')
flow.authentication = FlowAuthenticationRequirement.NONE
flow.save()
print('Flow authentication:', flow.authentication)
"
```

**Verify the recovery flow exists:**
```bash
kubectl exec -n authentik deployment/authentik-server -- \
  ak shell -c "from authentik.flows.models import Flow; print(list(Flow.objects.filter(slug='default-recovery-flow').values('slug','name','designation')))"
```

---

## LDAP

Authentik ships with a built-in LDAP outpost, useful for services that do not support OIDC (e.g. Jellyfin). The outpost auto-deploys as a Kubernetes Service when created in the UI — no manifest is needed.

### DN structure

All Authentik LDAP entries live under the provider's Base DN (`DC=ldap,DC=goauthentik,DC=io` by default):

| Entry type | DN |
|---|---|
| Regular user | `cn=<username>,ou=users,DC=ldap,DC=goauthentik,DC=io` |
| Service account | `cn=<username>,ou=users,DC=ldap,DC=goauthentik,DC=io` |
| Group | `cn=<group>,ou=groups,DC=ldap,DC=goauthentik,DC=io` |

> **Note:** Both regular users and service accounts land in `ou=users`, not `ou=serviceaccounts`.
> Using the root DN (`DC=ldap,DC=goauthentik,DC=io`) as a search base returns an Operations Error — always use `ou=users,...` or `ou=groups,...`.

---

### Full setup procedure

#### 1. Create an LDAP Provider

**Applications → Providers → Create → LDAP Provider**

| Field | Value |
|---|---|
| Name | descriptive, e.g. `Jellyfin LDAP` |
| Bind flow | `default-authentication-flow` |
| Base DN | `DC=ldap,DC=goauthentik,DC=io` |
| Search mode | `direct` (queries Authentik API per search — no stale cache) |
| Bind mode | `direct` |

#### 2. Create an Application

**Applications → Applications → Create**

| Field | Value |
|---|---|
| Name | e.g. `Jellyfin LDAP` |
| Slug | e.g. `jellyfin-ldap` |
| Provider | select the provider from step 1 |

Add policy bindings to control who can access this application:
- Bind the users or groups that should be able to log in via LDAP.
- Once _any_ binding is added, Authentik switches from "allow all" to "allow bound only". Make sure the bind user (step 3) is also bound, or it will lose access immediately.

#### 3. Create a bind user (service account)

The LDAP bind user is the account the application uses to search the directory before authenticating the real user. It is **not** the end user.

**Admin → Directory → Users → Create**

| Field | Value |
|---|---|
| Username | e.g. `jellyfin-ldap-bind` |
| Type | **Service account** |

After creation, set a password via **Set Password** and note it down. Add the bind user to whichever group(s) you bind in step 2 (e.g. `family&friends`) so it passes its own access policy.

#### 4. Grant the bind user the `search_full_directory` permission

Without this permission, when the bind user performs an LDAP search the outpost returns **only the bind user themselves**. This is gated by the Go outpost code — `flags.CanSearch` is set from the `has_search_permission` field on `/api/v3/outposts/ldap/{pk}/check_access/`, which is `True` only if the user has `authentik_providers_ldap.search_full_directory` (model-level or object-level on the LDAP provider).

**Admin → Directory → Roles → Create**

| Field | Value |
|---|---|
| Name | `ldap-searcher` |

Open the role → **Assign permissions to objects** → pick the LDAP provider → check **Search full LDAP directory**.

Then **Admin → Directory → Users → \<bind user\> → Roles → assign `ldap-searcher`**.

> Older guidance suggested adding the bind user to a group with `is_superuser=True`. That works (superusers bypass the perm check), but it's overkill — the bind user inherits all admin rights. The explicit `search_full_directory` role-perm is the principle-of-least-privilege option and is what the OpenTofu config in this repo applies.

#### 5. Create the LDAP Outpost

**Applications → Outposts → Create**

| Field | Value |
|---|---|
| Name | e.g. `LDAP Outpost` |
| Type | **LDAP** |
| Applications | select the application from step 2 |

Authentik auto-deploys a pod and Service in the `authentik` namespace:

```
Service: ak-outpost-ldap-outpost.authentik.svc.cluster.local
Port 389 (LDAP, plain)
Port 636 (LDAPS)
```

No Kubernetes manifest is required. Verify it's running:

```bash
kubectl get pods -n authentik | grep ldap
kubectl get svc -n authentik | grep ldap
```

---

### Configuring the application (Jellyfin example)

These are the exact settings that work with Authentik's LDAP outpost:

| Jellyfin field | Value |
|---|---|
| LDAP Server | `ak-outpost-ldap-outpost.authentik.svc.cluster.local` |
| LDAP Port | `389` |
| Secure LDAP | Unchecked (internal cluster traffic) |
| LDAP Bind User | `cn=jellyfin-ldap,ou=users,DC=ldap,DC=goauthentik,DC=io` |
| LDAP Bind User Password | password set in step 3 |
| **LDAP Base DN for Searches** | `ou=users,DC=ldap,DC=goauthentik,DC=io` |
| LDAP User Filter | `(objectClass=user)` |
| LDAP Search Attributes | `uid,cn,mail,displayName` |
| LDAP UID Attribute | `uid` |
| LDAP Username Attribute | `cn` |
| Enable User Creation | Checked |

> **Base DN warning:** The Base DN field is sensitive to trailing spaces and incomplete DNs.
> - `ou=users` alone → parse error ("DN ended with incomplete type, value pair")
> - `ou=users,DC=ldap,DC=goauthentik,DC=io ` (trailing space) → "Found 0 Entities"
> - `ou=users,DC=ldap,DC=goauthentik,DC=io` (exact) → correct
>
> Type the value by hand rather than pasting to avoid invisible whitespace.

> **Jellyfin restart required:** The LDAP plugin settings note states "Making changes to this configuration requires a restart of Jellyfin." Changes do not take effect until the pod is restarted — the test buttons will use the old config if you skip the restart.

---

### Troubleshooting LDAP

**Base Search: Operations Error**
The Base DN is using the root (`DC=ldap,DC=goauthentik,DC=io`) instead of an OU. Change it to `ou=users,DC=ldap,DC=goauthentik,DC=io`.

**Base Search: Found 0 Entities**
Usually a trailing space or typo in the Base DN field. Clear the field and retype it exactly.

**User Filter: Found 0 users**
The bind user doesn't have search permission. Check:
1. The bind user is `type: internal` (not `service_account`)
2. The bind user is a member of a group with `is_superuser=True`

Verify from the shell:
```bash
kubectl exec -n authentik deployment/authentik-server -- ak shell -c "
from authentik.core.models import User
u = User.objects.get(username='jellyfin-ldap')
print('type:', u.type, '| is_superuser:', u.is_superuser)
print('groups:', list(u.ak_groups.values_list('name', flat=True)))
"
```

**Bind (Success) but user still not found after adding policy bindings**
When the first binding is added to an application, Authentik switches from open access to restricted access. The bind user must also have a policy binding, or it loses LDAP access immediately.

**Live outpost log inspection:**
```bash
kubectl logs -n authentik $(kubectl get pods -n authentik -l app.kubernetes.io/name=ak-outpost-ldap-outpost -o name) --since=60s -f
```
The logs show every bind and search request with the exact `baseDN`, `filter`, and `took-ms`. A `took-ms: 0` on a search means the outpost rejected the request before querying Authentik (parse error or no search permission).

---

## Reference

| Resource | Value |
|---|---|
| Authentik URL | `https://authentik.tailnet.ts.net` |
| Login (akadmin) | `https://authentik.tailnet.ts.net` |
| Namespace | `authentik` |
| Credentials secret | `authentik-credentials` |
| PostgreSQL cluster | `authentik-db` (CNPG) |
| Traefik middleware | `authentik-forward-auth` (namespace `authentik`) |
| Middleware ref (Ingress) | `authentik-authentik-forward-auth@kubernetescrd` |

**See also:**

- [gitops-flux.md](gitops-flux.md) — patched secrets pattern, Flux reconciliation
- [new-service.md](new-service.md) — end-to-end guide for adding a new service with TLS and ForwardAuth
