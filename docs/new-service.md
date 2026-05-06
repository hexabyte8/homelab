# Adding a New Service

This guide is the canonical reference for deploying a new application to the homelab k3s cluster. It covers everything from creating manifests to having the service live and accessible.

---

## Overview

Every service follows the same GitOps flow:

1. Write Kubernetes manifests under `k3s/manifests/<myapp>/`
2. Create a Flux `Kustomization` (or `HelmRelease`) in `k3s/flux/apps/<myapp>.yaml` and add it to `k3s/flux/apps/kustomization.yaml`
3. Commit and push — Flux reconciles within the interval (default 10 min) or immediately if you run `flux reconcile kustomization apps -n flux-system`

Optionally:

- Add a DNS record and tunnel ingress entry in `opentofu/cloudflare-tunnel.tf` (for Cloudflare Tunnel services)
- Configure Authentik to protect the service behind SSO
- To park (disable) the service later, remove its entry from `k3s/flux/apps/kustomization.yaml` and commit

---

## Decision Points

Before writing any YAML, answer these four questions:

| Question           | Options                                                                                                                                       |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| **Ingress**        | [Tailscale](#option-a-tailscale-ingress) (private, tailnet only) · [Cloudflare Tunnel](#option-b-cloudflare-tunnel-ingress) (public internet) |
| **Authentication** | None · [Authentik ForwardAuth](#step-4-add-authentik-protection) (Traefik only)                                                               |
| **Storage**        | Ephemeral (no PVC) · [Longhorn PVC](#pvcyaml-optional)                                                                                        |
| **Database**       | None · CNPG PostgreSQL (see existing `authentik-db` cluster as reference)                                                                     |

!!! note "Authentik ForwardAuth requires Traefik"
The `authentik-forward-auth` middleware only applies to Traefik-routed traffic. If you choose Tailscale Ingress, Authentik ForwardAuth is **not available** — Tailscale proxies bypass Traefik entirely. For public services requiring SSO, use Cloudflare Tunnel.

---

## Step 1: Create the Manifests Directory

```bash
mkdir k3s/manifests/myapp
```

All manifests for the service live here. Flux applies every `.yaml` file in the directory.

---

## Step 2: Core Manifests

### `namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
```

!!! tip
The Flux Kustomization can create namespaces automatically, but including a `namespace.yaml`
is good practice — it lets you add namespace-level labels and ensures the namespace is tracked
in git. Alternatively, add the namespace to `k3s/flux/apps/namespaces.yaml`.

### `deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: myapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
        - name: myapp
          image: ghcr.io/example/myapp:1.0.0
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: myapp-data
```

!!! note "Resource limits"
Always set `resources.requests` and `resources.limits`. This ensures the scheduler places the pod correctly and prevents a runaway container from starving the node.

!!! note "Image tags and Flux"
Flux reconciles based on the manifest content in git. If you change `:1.0.0` → `:1.0.1` in git and push, Flux applies the update. If you use `:latest`, Flux will only redeploy when something else in the manifest changes. Prefer immutable tags for predictable rollouts.

### `service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: myapp
spec:
  type: ClusterIP
  selector:
    app: myapp
  ports:
    - port: 8080
      targetPort: 8080
```

### `pvc.yaml` (optional)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: myapp-data
  namespace: myapp
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

Longhorn is the default storage class. `ReadWriteOnce` is sufficient for single-replica deployments. Use `ReadWriteMany` only if multiple pods need simultaneous write access (requires a different storage class).

---

## Step 3: Choose Your Ingress

### Option A: Tailscale Ingress

**Use when:** The service is for personal/internal use and only needs to be accessible to Tailscale network members.

The Tailscale operator watches for Ingresses with `ingressClassName: tailscale` and automatically provisions a proxy pod that joins the `your-tailnet` tailnet. TLS is handled automatically — no cert-manager needed.

**`ingress.yaml`**:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
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
        - myapp # ← hostname only, no domain
```

The value under `tls.hosts` becomes the MagicDNS hostname. After Flux syncs, the service is available at:

```
https://myapp.tailnet.ts.net
```

!!! tip "Tailscale Funnel (public access via Tailscale)"
To make a Tailscale-hosted service reachable on the public internet without Cloudflare, add the Funnel annotations:

    ```yaml
    metadata:
      annotations:
        tailscale.com/proxy-class: "funnel"
        tailscale.com/funnel: "true"
    ```

    Funnel exposes the service at `https://myapp.tailnet.ts.net` publicly. No DNS record or cert-manager configuration is needed — Tailscale handles TLS. Note that Authentik ForwardAuth is still not available via this path.

See [tailscale-operator.md](tailscale-operator.md) for proxy classes and further configuration.

---

### Option B: Cloudflare Tunnel Ingress

**Use when:** The service needs to be accessible from the public internet.

Traffic flows: `Internet → Cloudflare Edge → cloudflared daemon (in cluster) → Traefik → your pod`

The `cloudflared` deployment in the `cloudflared` namespace maintains a persistent outbound tunnel to Cloudflare. Routing rules and DNS records are managed via OpenTofu in `opentofu/cloudflare-tunnel.tf`. Traefik handles TLS termination with cert-manager.

**`ingress.yaml`**:

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
    - host: myapp.example.com
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
        - myapp.example.com
      secretName: myapp-tls
```

**Then add the tunnel routing and DNS record in OpenTofu:**

In `opentofu/cloudflare-tunnel.tf`, add an entry to the `ingress` list in `cloudflare_zero_trust_tunnel_cloudflared_config.homelab` (before the catch-all) and a new DNS record resource:

```hcl
# In the ingress list (before the catch-all http_status:404 entry):
{
  hostname = "myapp.${var.cloudflare_zone_name}"
  service  = "http://traefik.kube-system.svc.cluster.local:80"
},

# New resource in the same file:
resource "cloudflare_dns_record" "myapp" {
  zone_id = var.cloudflare_zone_id
  name    = "myapp"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}
```

This tells cloudflared to forward all traffic for `myapp.example.com` into the cluster via Traefik. The Kubernetes Ingress object above then routes it to the correct pod based on the `Host` header.

---

## Step 4: Add Authentik Protection

**Applies to: Cloudflare Tunnel (Traefik) ingress only.**

The `authentik-forward-auth` Traefik Middleware is already deployed in the `authentik` namespace. Add the annotation to your Ingress to gate the service behind Authentik SSO:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    traefik.ingress.kubernetes.io/router.middlewares: >-
      kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd
```

!!! note "Two middlewares required for Cloudflare Tunnel"
When traffic arrives via Cloudflare Tunnel, `cloudflared` connects to Traefik over plain `http://`, causing Traefik to set `X-Forwarded-Proto: http`. Authentik uses this header to build the OIDC callback URL — if it says `http`, Authentik rejects the callback as invalid.

    The `kube-system-cloudflare-https-scheme@kubernetescrd` middleware (defined in `k3s/manifests/traefik/cloudflare-https-middleware.yaml`) rewrites `X-Forwarded-Proto` to `https` **before** ForwardAuth runs. Always chain it first.

**Also configure the provider in OpenTofu:**

Add a `authentik_provider_proxy` + `authentik_application` block in `opentofu/authentik.tf`,
append the provider's id to `authentik_outpost.embedded.protocol_providers`, then push to
`main` (OpenTofu Apply runs automatically).

**Or configure the application in the Authentik web UI (If not managing via Terraform/Tofu):**

1. Log in at **<https://authentik.tailnet.ts.net>**
2. Go to **Applications → Providers → Create**
3. Choose **Proxy Provider** and fill in:
   - **Name**: `myapp-proxy-provider`
   - **Authorization flow**: `default-provider-authorization-implicit-consent`
   - **Forward auth (single application)**
   - **External host**: `https://myapp.example.com`
4. Go to **Applications → Applications → Create**:
   - **Name**: `My App`
   - **Slug**: `myapp`
   - **Provider**: select `myapp-proxy-provider`
5. Go to **Applications → Outposts**, edit the **embedded outpost**, and add `myapp` to the list of assigned applications.

After the outpost updates (usually within 30 seconds), unauthenticated requests to `myapp.example.com` will be redirected to the Authentik login page.

!!! tip "If the service has a built-in login page"
Add `UPTIME_KUMA_DISABLE_AUTH: "1"` (or the service's equivalent env var) to the Deployment so users only see the Authentik login. Without this, users must authenticate twice. The env var approach is DR-resilient (survives PVC loss) vs. a UI toggle stored only in the volume. See [authentik.md](authentik.md#forwardauth-with-services-that-have-built-in-auth) for a table of common env vars and the Tailscale backdoor caveat.

See [authentik.md](authentik.md) for more detail on provider types and the ForwardAuth architecture.

---

## Step 5: Register with Flux

Create `k3s/flux/apps/myapp.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 2m
  timeout: 5m
  prune: true
  wait: false
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./k3s/manifests/myapp
  targetNamespace: myapp
```

Add an entry to `k3s/flux/apps/kustomization.yaml`:

```yaml
resources:
  # ... existing entries ...
  - myapp.yaml
```

For a Helm-based service, create a `HelmRelease` instead — see [gitops-flux.md](gitops-flux.md#helm-chart) for the full template and HelmRepository setup.

---

## Step 6: Add DNS Record and Tunnel Route (Cloudflare Tunnel only)

Edit `opentofu/cloudflare-tunnel.tf` to add both an ingress entry in the existing `cloudflare_zero_trust_tunnel_cloudflared_config.homelab` resource and a new `cloudflare_dns_record` resource:

```hcl
# 1. Add to the ingress list inside cloudflare_zero_trust_tunnel_cloudflared_config.homelab
#    (before the catch-all http_status:404 entry):
{
  hostname = "myapp.${var.cloudflare_zone_name}"
  service  = "http://traefik.kube-system.svc.cluster.local:80"
},

# 2. Add a new DNS record resource in the same file:
resource "cloudflare_dns_record" "myapp" {
  zone_id = var.cloudflare_zone_id
  name    = "myapp"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}
```

The `content` uses a resource reference so the tunnel UUID never needs to be hard-coded.

Pushing to `main` automatically triggers the **OpenTofu Apply** GitHub Actions workflow — no manual `tofu apply` is needed.

!!! note "Skip this step for Tailscale"
Tailscale Ingress and Funnel manage their own DNS automatically. No OpenTofu changes are needed.

---

## Step 7: Commit and Deploy

```bash
git add k3s/manifests/myapp/ k3s/flux/apps/myapp.yaml k3s/flux/apps/kustomization.yaml opentofu/cloudflare-tunnel.tf
git commit -m "feat: add myapp service"
git push
```

Flux reconciles within the default interval (10 minutes). Force immediate reconciliation with:

```bash
flux reconcile kustomization apps -n flux-system
```

---

## Parking or Re-Enabling a Service

To temporarily disable a service without deleting its manifests, remove its entry from `k3s/flux/apps/kustomization.yaml`:

```bash
# Edit k3s/flux/apps/kustomization.yaml — remove the line:
#   - myapp.yaml
git commit -am "chore: park myapp"
git push
```

Flux prunes the live resources on the next reconciliation. To re-enable, add the line back and push.

---

## Step 8: Update the Dashy Dashboard

Add a tile for the new service in `k3s/manifests/dashy/configmap.yaml` so it appears on the homelab dashboard at <https://dashy.tailnet.ts.net>:

1. Find the appropriate section under `sections:` (or add a new one)
2. Append a new item:

   ```yaml
   - title: My App
     description: What it does
     url: https://myapp.tailnet.ts.net # or example.com URL
     icon: hl-myapp # see docs/dashy.md for icon options
     target: newtab
   ```

3. Bump the `kubectl.kubernetes.io/restartedAt` annotation in `k3s/manifests/dashy/deployment.yaml` to the current timestamp — this ensures Flux rolls the Dashy pod to pick up the new config.

Include both files in the same commit as the rest of your service manifests.

See [dashy.md](dashy.md) for full configuration options (themes, status checks, sections, icons).

---

## Step 9: Verify

```bash
# Flux Kustomization is Ready
flux get kustomization myapp -n flux-system

# Pod is running
kubectl get pods -n myapp

# Ingress was created and has an address
kubectl get ingress -n myapp

# TLS certificate issued (Cloudflare Tunnel only)
kubectl get certificate -n myapp

# Describe ingress for detailed event log
kubectl describe ingress myapp -n myapp
```

For Tailscale Ingress, check that the proxy StatefulSet was created:

```bash
kubectl get statefulset -n tailscale
```

The service should be reachable at `https://myapp.tailnet.ts.net` (Tailscale) or `https://myapp.example.com` (Cloudflare Tunnel) within a few minutes of Flux reconciling.

---

## Common Patterns Reference

### Longhorn PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: myapp-data
  namespace: myapp
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

### Environment variable from a Secret

```yaml
# In the Secret
apiVersion: v1
kind: Secret
metadata:
  name: myapp-credentials
  namespace: myapp
type: Opaque
stringData:
  api-key: "REPLACE_ME"
```

```yaml
# In the Deployment container spec
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: myapp-credentials
        key: api-key
```

!!! warning "Secrets in git"
Never commit real secret values. Commit a placeholder (`REPLACE_ME`) and patch the
live value with `kubectl patch` after Flux creates the object. Annotate the secret with
`kustomize.toolkit.fluxcd.io/reconcile: disabled` so Flux never resets it. See
[gitops-flux.md](gitops-flux.md#patched-secrets) for the full pattern and the list of
currently patched secrets.

### Init container for permission fixing

Some images (especially those running as non-root) require the mounted volume to be owned by a specific UID before startup:

```yaml
initContainers:
  - name: init-permissions
    image: busybox:1.36
    command: ["sh", "-c", "chown -R 1000:1000 /data"]
    volumeMounts:
      - name: data
        mountPath: /data
```

### Multiple ports

```yaml
# In the Deployment
ports:
  - containerPort: 8080
    name: http
  - containerPort: 9090
    name: metrics

# In the Service
ports:
  - port: 8080
    targetPort: 8080
    name: http
  - port: 9090
    targetPort: 9090
    name: metrics
```

### Resource limits reference

| Service size                  | CPU request | CPU limit | Memory request | Memory limit |
| ----------------------------- | ----------- | --------- | -------------- | ------------ |
| Small (static site, exporter) | `10m`       | `100m`    | `32Mi`         | `128Mi`      |
| Medium (typical web app)      | `50m`       | `500m`    | `128Mi`        | `512Mi`      |
| Large (media, database)       | `200m`      | `2000m`   | `512Mi`        | `2Gi`        |

---

## See Also

- [gitops-flux.md](gitops-flux.md) — Flux bootstrap, patched secrets, adding services recipe
- [tailscale-operator.md](tailscale-operator.md) — Proxy classes, Funnel, MagicDNS hostname format
- [authentik.md](authentik.md) — ForwardAuth deep-dive, OIDC provider setup, LDAP outpost
