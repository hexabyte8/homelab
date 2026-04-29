# GitHub Copilot Instructions for Homelab Repository

## Repository Overview

This homelab is managed using GitOps and Infrastructure as Code (IaC). The **primary workload platform is a k3s Kubernetes cluster** running on Proxmox VMs, reconciled by **Flux CD** (kustomize-controller + helm-controller). OpenTofu manages cloud infrastructure (Cloudflare DNS/Tunnels, Proxmox VMs, Tailscale, AWS S3). Ansible handles VM-level provisioning (not in-cluster service deployment).

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Virtualization** | Proxmox | Hosts k3s VMs |
| **Kubernetes** | k3s | Application runtime (server + 2 agents) |
| **GitOps** | Flux CD | Reconciles `k3s/flux/` and `k3s/manifests/` to the cluster |
| **Ingress** | Traefik | In-cluster reverse proxy (built into k3s) |
| **TLS** | cert-manager + Let's Encrypt | Automatic certificate provisioning |
| **Storage** | Longhorn | Persistent volumes |
| **Public tunnel** | Cloudflare Tunnel (`cloudflared`) | Exposes services on `chronobyte.net` |
| **Private networking** | Tailscale operator | Exposes services on `daggertooth-scala.ts.net` |
| **Auth / SSO** | Authentik | ForwardAuth proxy, OIDC, LDAP |
| **Database** | CNPG (CloudNativePG) | PostgreSQL clusters |
| **IaC** | OpenTofu | Cloudflare, Proxmox VMs, Tailscale ACLs, S3 |
| **Secrets** | Bitwarden Secrets Manager | Injected into GitHub Actions workflows |
| **CI/CD** | GitHub Actions | OpenTofu plan/apply, Ansible playbooks |

## Repository Structure

```
.
├── k3s/
│   ├── flux/                  # Flux configuration (the GitOps controller)
│   │   ├── clusters/k3s/      # Root + flux-system bootstrap (apps.yaml, sources.yaml)
│   │   └── apps/              # One Flux Kustomization (or HelmRelease) per service
│   └── manifests/             # ALL Kubernetes manifests — reconciled by Flux
│       ├── authentik/         # Authentik SSO deployment
│       ├── cert-manager/      # cert-manager + ClusterIssuer
│       ├── cloudflared/       # Cloudflare Tunnel daemon
│       ├── longhorn/          # Longhorn storage
│       ├── tailscale/         # Tailscale operator
│       ├── traefik/           # Traefik customisation (HelmChartConfig, middlewares)
│       └── <service>/         # One directory per deployed service
├── opentofu/                  # IaC for cloud/VM infrastructure
│   ├── main.tf                # Provider config + S3 backend
│   ├── variables.tf           # All variable definitions
│   ├── cloudflare.tf          # DNS records (non-tunnel)
│   ├── cloudflare-tunnel.tf   # Cloudflare Tunnel config + DNS records
│   ├── k3s.tf                 # Proxmox VMs for k3s cluster
│   ├── tailscale.tf           # Tailscale ACLs + auth keys
│   └── s3.tf                  # AWS S3 buckets
├── ansible/                   # VM-level provisioning only (not k8s services)
└── .github/workflows/         # CI/CD: opentofu-plan, opentofu-apply, ansible-*
```

## Cluster & Networking Facts

| Fact | Value |
|---|---|
| **Public domain** | `chronobyte.net` (DNS on Cloudflare) |
| **Tailnet** | `daggertooth-scala` (private, `*.daggertooth-scala.ts.net`) |
| **Traefik ClusterIP** | `traefik.kube-system.svc.cluster.local:80` |
| **Authentik URL** | `https://authentik.daggertooth-scala.ts.net` |
| **Authentik ClusterIP** | `authentik-server.authentik.svc.cluster.local:80` |
| **Cloudflare Tunnel ID** | _managed in OpenTofu (loaded from Bitwarden Secrets Manager — never hardcode)_ |
| **cert-manager ClusterIssuer** | `letsencrypt-production` |
| **Longhorn storage class** | `longhorn` |

---

## How to Expose a Service — Decision Guide

When a user asks to add or expose a service, choose the exposure method based on the intended audience:

### 1. Internal only (no external access)
- ClusterIP Service + no Ingress
- Accessible only from within the cluster
- Example: database sidecars, internal APIs

### 2. Private — Tailscale (tailnet members only)
**Use when:** The service is personal/team use, tailnet-only, no public access needed.

- `ingressClassName: tailscale`
- Tailscale operator provisions a proxy pod automatically
- TLS handled by Tailscale — **no cert-manager needed**
- Accessible at: `https://<hostname>.daggertooth-scala.ts.net`
- **Authentik ForwardAuth is NOT available** via Tailscale Ingress (traffic bypasses Traefik)

```yaml
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 8080
  tls:
    - hosts:
        - myapp   # hostname only — becomes myapp.daggertooth-scala.ts.net
```

### 3. Private — Tailscale Funnel (public internet via Tailscale, no custom domain)
**Use when:** Quick public access is needed but a custom domain is not required.

- Same as Tailscale Ingress but with Funnel annotations
- Accessible publicly at `https://myapp.daggertooth-scala.ts.net`
- No DNS record or cert-manager needed
- **Authentik ForwardAuth is NOT available** via Tailscale Funnel

```yaml
metadata:
  annotations:
    tailscale.com/proxy-class: "funnel"
    tailscale.com/funnel: "true"
spec:
  ingressClassName: tailscale
  ...
```

### 4. Public — Cloudflare Tunnel (custom domain, public internet)
**Use when:** The service needs a proper `*.chronobyte.net` URL, public internet access, or Authentik protection.

Traffic path: `Internet → Cloudflare Edge → cloudflared (cluster) → Traefik → Pod`

**Requires three things:**

#### A. Kubernetes Ingress (Traefik)
`ingressClassName: traefik`, with TLS via cert-manager:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  ingressClassName: traefik
  rules:
    - host: myapp.chronobyte.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 8080
  tls:
    - hosts:
        - myapp.chronobyte.net
      secretName: myapp-tls
```

#### B. OpenTofu — tunnel route + DNS record
In `opentofu/cloudflare-tunnel.tf`:

```hcl
# Add to the ingress list in cloudflare_zero_trust_tunnel_cloudflared_config.homelab
# (before the catch-all http_status:404 entry):
{
  hostname = "myapp.${var.cloudflare_zone_name}"
  service  = "http://traefik.kube-system.svc.cluster.local:80"
},

# New DNS record resource:
resource "cloudflare_dns_record" "myapp" {
  zone_id = var.cloudflare_zone_id
  name    = "myapp"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}
```

#### C. Commit and push
Pushing to `main` triggers OpenTofu Apply automatically (GitHub Actions). Flux reconciles the Ingress within ~10 minutes (sooner with `flux reconcile kustomization apps`).

---

## Adding Authentik SSO / ForwardAuth

**Only available with Cloudflare Tunnel (Traefik) ingress.** Authentik ForwardAuth cannot be applied to Tailscale Ingress or Tailscale Funnel.

### Middleware chain (CRITICAL)

When adding Authentik to a Cloudflare Tunnel service, **two middlewares must be chained in this order**:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: >-
  kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd
```

**Why two middlewares?**
- `cloudflared` connects to Traefik over `http://`, so Traefik sets `X-Forwarded-Proto: http`
- Authentik uses this header to build the OIDC callback URL; if it says `http`, auth fails with a 400 error
- `cloudflare-https-scheme` (namespace `kube-system`) rewrites the header to `https` *before* ForwardAuth runs

**Full Ingress with Authentik:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    traefik.ingress.kubernetes.io/router.middlewares: >-
      kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
    - host: myapp.chronobyte.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 8080
  tls:
    - hosts:
        - myapp.chronobyte.net
      secretName: myapp-tls
```

### Authentik web UI steps (required after deploying the Ingress)

After the Kubernetes Ingress is synced, three steps in the Authentik UI are required:

1. **Create a Proxy Provider** — Applications → Providers → Create → Proxy Provider
   - Mode: `Forward auth (single application)`
   - External Host: `https://myapp.chronobyte.net` (exact `https://` URL, no trailing path)

2. **Create an Application** — Applications → Applications → Create
   - Link to the provider created above
   - Launch URL: `https://myapp.chronobyte.net`

3. **Assign to the Embedded Outpost** — Applications → Outposts → Edit `authentik Embedded Outpost`
   - Move the new application to the "selected" list and save

The outpost updates within ~30 seconds. See `docs/authentik.md` for the full procedure.

---

## Adding a New Service — Full Checklist

The canonical guide is `docs/new-service.md`. Summary:

1. Create `k3s/manifests/<myapp>/` with `namespace.yaml`, `deployment.yaml`, `service.yaml` (and optionally `pvc.yaml`)
2. Create `k3s/flux/apps/<myapp>.yaml` — Flux `Kustomization` (or `HelmRelease`) pointing at `./k3s/manifests/<myapp>`
3. Choose exposure method:
   - **Tailscale only** → `ingress.yaml` with `ingressClassName: tailscale`
   - **Cloudflare public** → `ingress.yaml` with `ingressClassName: traefik` + TLS + OpenTofu changes
4. If Authentik is wanted → add the middleware chain annotation + configure in Authentik UI
5. Commit and push — Flux and OpenTofu Apply handle the rest

---

## Coding Standards

### Kubernetes Manifests

- All manifests live under `k3s/manifests/<service>/`
- Every service gets its own Flux `Kustomization` (or `HelmRelease`) under `k3s/flux/apps/<service>.yaml`
- Always set `resources.requests` and `resources.limits` on containers
- Use `storageClassName: longhorn` for persistent volumes
- Secrets committed to git use placeholder values (`REPLACE_ME`); real values are patched with `kubectl patch --type=merge` after Flux creates the object
- Add `kustomize.toolkit.fluxcd.io/reconcile: disabled` as a metadata annotation on patched objects so Flux's drift correction doesn't overwrite the live values

### OpenTofu

- **Provider**: Cloudflare v5 — resources are `cloudflare_dns_record`, `cloudflare_zero_trust_tunnel_cloudflared`, `cloudflare_zero_trust_tunnel_cloudflared_config`
- **State backend**: AWS S3 (`chronobyte-homelab-tf-state` bucket, `homelab-tf-state-lock` DynamoDB table)
- All variables defined in `variables.tf`; sensitive values in `*.tfvars` (gitignored)
- Cloudflare API token needs: `Zone: DNS Edit`, `Zone: Zone Read`, `Account: Cloudflare Tunnel Edit`, `Account: Zero Trust Edit`
- OpenTofu Apply runs automatically on push to `main` via GitHub Actions

### Ansible (VM provisioning only)

- Ansible is for VM-level setup (packages, Docker, system config) — **not** for deploying k8s services
- Use FQCN module names (`ansible.builtin.*`)
- Validate env vars with `assert` in `pre_tasks`
- Secrets injected via Bitwarden Secrets Manager in GitHub Actions workflows

### GitHub Actions

- OpenTofu: `opentofu-plan.yml` (PRs) and `opentofu-apply.yml` (push to main)
- Ansible: thin workflow per playbook (`ansible-<task>.yml` → `ansible/playbooks/<task>.yml`)
- Cluster bootstrap: `k3s-manifests.yml` (one-shot bootstrap), `k3s-patch-secrets.yml` (patches `REPLACE_ME` secrets live from Bitwarden)
- Secret injection pattern: Bitwarden Secrets Manager → env vars → workflow steps
- All secrets stored in Bitwarden Secrets Manager and referenced by UUID in workflows

---

## Key Infrastructure Resources

| Resource | Location | Notes |
|---|---|---|
| Flux Kustomizations | `k3s/flux/apps/` | One `.yaml` per service |
| Flux bootstrap (root + sources) | `k3s/flux/clusters/k3s/` | `apps.yaml`, `sources.yaml`, `flux-system/` |
| Cloudflare tunnel routes | `opentofu/cloudflare-tunnel.tf` | Edit to add/remove hostnames |
| Cloudflare DNS records | `opentofu/cloudflare.tf` (non-tunnel) and `opentofu/cloudflare-tunnel.tf` (tunnel) | |
| Authentik ForwardAuth middleware | `k3s/manifests/authentik/traefik-middleware.yaml` | Namespace `authentik` |
| HTTPS scheme fix middleware | `k3s/manifests/traefik/cloudflare-https-middleware.yaml` | Namespace `kube-system` |
| Traefik HelmChartConfig | `k3s/manifests/traefik/helm-chart-config.yaml` | Trusts RFC1918 forwarded headers |
| cloudflared configmap | `k3s/manifests/cloudflared/configmap.yaml` | `protocol: http2` required (QUIC blocked) |
| cloudflared token secret | `k3s/manifests/cloudflared/secret.yaml` | Placeholder in git; patched live |

---

## Existing Services

| Service | Namespace | Exposure | Authentik |
|---|---|---|---|
| Flux CD | `flux-system` | (controller — not a user-facing service) | N/A |
| Authentik | `authentik` | Tailscale | N/A (is the IdP) |
| AdGuard Home | `adguard` | Tailscale | No |
| Docs (MkDocs) | `docs` | Tailscale | No |
| Jellyfin | `jellyfin` | Tailscale | No |
| Filebrowser | `jellyfin` | Tailscale | No |
| Transmission | `jellyfin` | Tailscale | No |
| Uptime Kuma | `uptime-kuma` | Tailscale (internal) + Cloudflare Tunnel (public) | Yes (public path) |

---

## Documentation

| Document | Purpose |
|---|---|
| `docs/new-service.md` | **Canonical** step-by-step guide for adding any new service |
| `docs/authentik.md` | Authentik architecture, ForwardAuth setup, OIDC, LDAP |
| `docs/cloudflare-tunnels.md` | Cloudflare Tunnel deployment, routing, Authentik integration |
| `docs/tailscale-operator.md` | Tailscale Ingress, Funnel, proxy classes |
| `docs/gitops-flux.md` | Flux CD architecture, Kustomization/HelmRelease patterns, secrets patching |
| `docs/disaster-recovery/` | Full cluster rebuild runbooks |

Always read the relevant doc before making changes to the corresponding system.

---

## Tips for AI Assistance

1. **When the user asks to add/expose a service**, first determine:
   - Who is the audience? (personal/tailnet → Tailscale; public → Cloudflare Tunnel)
   - Is authentication needed? (only possible with Cloudflare Tunnel + Traefik)
   - Is persistence needed? (Longhorn PVC)

2. **Never use `kubectl apply` for secrets** — use `kubectl patch --type=merge`. Flux uses Server-Side Apply and will conflict with `apply`.

3. **Flux drift correction will overwrite secrets** unless the object carries the `kustomize.toolkit.fluxcd.io/reconcile: disabled` annotation.

4. **The `cloudflare-https-scheme` middleware must always come first** when chaining with `authentik-forward-auth` on Cloudflare Tunnel ingresses.

5. **Authentik requires 3 steps in the web UI** after creating a Cloudflare Tunnel ingress: Provider → Application → Outpost assignment.

6. **OpenTofu Apply is automatic** — committing changes to `opentofu/cloudflare-tunnel.tf` and pushing to `main` is sufficient to apply them. No manual `tofu apply` needed.

7. **Tailscale Ingress bypasses Traefik** — middlewares, ForwardAuth, and cert-manager do not apply to Tailscale-routed traffic.

8. **Secret patching is one-shot via `k3s-patch-secrets.yml`** — after committing a new `REPLACE_ME` secret, dispatch this workflow (or it runs automatically on push) to populate the live value from Bitwarden. Add a new entry to its `target` list + a corresponding patch step when introducing new secrets.
