# Authentik SSO

This document covers the Authentik deployment in the homelab k3s cluster - what it provides, how it's set up, and how to protect services with ForwardAuth.

---

## Overview

[Authentik](https://goauthentik.io/) is the identity provider (IdP) for the homelab cluster. It provides:

- **SSO** - single sign-on across all protected services
- **OIDC / OAuth2** - for apps that support standards-based authentication
- **LDAP** - for apps that only speak LDAP (via built-in LDAP outpost)
- **ForwardAuth** - proxy-level authentication via Traefik, so services without any auth support can be gated behind a login page

---

## Architecture

| Component                  | Detail                                                             |
| -------------------------- | ------------------------------------------------------------------ |
| **PostgreSQL**             | CNPG cluster `authentik-db` in the `authentik` namespace           |
| **Redis**                  | Authentik's built-in Redis (bundled in the Helm chart)             |
| **TLS**                    | cert-manager with ClusterIssuer `letsencrypt-production`           |
| **Ingress**                | Tailscale Funnel at `authentik.daggertooth-scala.ts.net`           |
| **Credentials secret**     | `authentik-credentials` (must be patched after deploy - see below) |
| **ForwardAuth middleware** | `authentik-forward-auth` in namespace `authentik`                  |

Flux manages the deployment via a `HelmRelease` in `k3s/flux/apps/authentik.yaml`. Once the HelmRelease reconciles, a few manual post-deploy steps are required before Authentik is usable.

---

## Flows as Code (OpenTofu)

All Authentik flows, stages, providers, applications and outpost membership in this homelab
are managed declaratively using the **goauthentik/authentik OpenTofu provider**. The Terraform
state lives alongside the rest of the homelab IaC in S3 (`opentofu/` directory).

### Adding a new ForwardAuth-protected app

1. Add an `authentik_provider_proxy` + `authentik_application`, append the provider's id to `authentik_outpost.embedded.protocol_providers`
2. Add the middleware chain `kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd` to the Kubernetes `Ingress`.

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

Some services (e.g. Uptime Kuma, Grafana, Gitea) ship with their own login page. When you add Authentik ForwardAuth in front of them, users hit **two logins in sequence** - Authentik first, then the service's own login. This is confusing and unnecessary.

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

| Service                    | Env var                      | Value    |
| -------------------------- | ---------------------------- | -------- |
| Uptime Kuma                | `UPTIME_KUMA_DISABLE_AUTH`   | `"1"`    |
| Grafana                    | `GF_AUTH_DISABLE_LOGIN_FORM` | `"true"` |
| Grafana (anonymous access) | `GF_AUTH_ANONYMOUS_ENABLED`  | `"true"` |

Check each service's documentation for the exact variable name.

> **Why env var and not the UI setting?** Many services allow disabling auth via a UI toggle that is then persisted in the service's data volume. That works fine day-to-day, but after a disaster recovery restore with a fresh PVC the volume is empty - the UI setting is gone and the service's login page reappears. The env var approach is baked into the Deployment manifest (committed to git) and survives any PVC loss.

**Alternative: UI setting**

Some services let you disable auth from within their admin panel (e.g. Grafana → Administration → Authentication). This is faster to set up but only persists in the PVC. Use the env var approach for any service you want to be fully DR-resilient.
