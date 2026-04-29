# Manifests & Helm

This page covers the cluster node reference and manual `kubectl` / `helm` escape hatches.
For the canonical GitOps workflow — how services are deployed, updated, and reconciled — see
**[gitops-flux.md](gitops-flux.md)** and **[new-service.md](new-service.md)**.

---

## Cluster Overview

| Node | Local IP | Tailscale IP | Role |
|---|---|---|---|
| k3s-server | <k3s-server-lan-ip> | <k3s-server-ts-ip> | control-plane |
| k3s-agent-1 | <k3s-agent-1-lan-ip> | <k3s-agent-1-ts-ip> | worker |
| k3s-agent-2 | <k3s-agent-2-lan-ip> | <k3s-agent-2-ts-ip> | worker |

**k3s version:** v1.34.5+k3s1

**Flannel networking:** Flannel uses Tailscale IPs as the overlay backend — see **[flannel-over-tailscale.md](flannel-over-tailscale.md)** for details.

### Installed components

| Component | Namespace | How installed |
|---|---|---|
| Traefik (ingress) | `kube-system` | k3s built-in |
| MetalLB | `metallb-system` | Flux GitOps (HelmRelease + Kustomization) |
| CloudNativePG operator | `cnpg-system` | Flux GitOps (HelmRelease) |
| Tailscale operator | `tailscale` | Flux GitOps (HelmRelease) |
| cert-manager | `cert-manager` | Flux GitOps (HelmRelease) |
| Longhorn | `longhorn-system` | Flux GitOps (HelmRelease) |
| Authentik | `authentik` | Flux GitOps (HelmRelease) |

---

## Manual Deployment (Escape Hatches)

Normal deployments go through Flux GitOps (commit → push → reconcile). The following
manual methods are available for bootstrapping, one-off operations, or debugging — not
for day-to-day service management.

### `kubectl apply` — one-off manifest

```bash
# Apply a single manifest file directly (bypasses Flux)
kubectl apply -f k3s/manifests/myapp/deployment.yaml

# Apply a whole directory
kubectl apply -f k3s/manifests/myapp/
```

!!! warning "Use `kubectl patch` for secrets, not `kubectl apply`"
    Flux uses Server-Side Apply (SSA). Running `kubectl apply` on a resource that Flux
    already owns will cause field-manager conflicts. For secrets in particular, always use
    `kubectl patch --type=merge`. See [gitops-flux.md](gitops-flux.md#patched-secrets).

### GitHub Actions — k3s Manifests workflow

Use the **k3s - Deploy Manifests** workflow dispatch for operations outside normal GitOps
(e.g., applying a manifest on a feature branch or force-deleting resources):

1. Go to **Actions → k3s - Deploy Manifests → Run workflow**.
2. Set **action** to `apply` or `delete`.
3. Set **manifest_path** to a file or directory relative to `k3s/manifests/`.
4. Set **target_host** (defaults to `k3s-server`).

### Helm (manual install)

Use manual `helm install` only for bootstrapping or debugging. For production services,
use a `HelmRelease` in `k3s/flux/apps/` so Flux manages lifecycle.

```bash
# Add a repo
helm repo add my-repo https://charts.example.com
helm repo update

# Install
helm install my-release my-repo/my-chart \
  --namespace my-namespace \
  --create-namespace \
  --values my-values.yaml

# Upgrade
helm upgrade my-release my-repo/my-chart --values my-values.yaml

# Uninstall
helm uninstall my-release -n my-namespace
```

---

## Tailscale Operator

> **Full documentation**: see **[tailscale-operator.md](tailscale-operator.md)** for the
> complete guide covering OAuth credential management, all three exposure methods
> (annotated Service, LoadBalancer, Tailscale Ingress), the `prod` ProxyClass, proxy
> naming, and troubleshooting.

The Tailscale operator runs in the `tailscale` namespace, deployed via Flux using the
official Helm chart (`tailscale-operator` v1.94.2 from `https://pkgs.tailscale.com/helmcharts`).
It provisions proxy StatefulSets that join the `your-tailnet` tailnet on behalf of
your Services and Ingresses.

### Quick reference

```yaml
# Expose a ClusterIP Service
metadata:
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "my-service"
    tailscale.com/proxy-class: "prod"

# Tailscale Ingress (HTTP — recommended for web services)
spec:
  ingressClassName: tailscale
  tls:
    - hosts:
        - my-service   # becomes my-service.tailnet.ts.net
```

---

## MetalLB Configuration

The MetalLB IP address pool and L2 advertisement are managed as a Flux Kustomization
pointing at `k3s/manifests/metallb-config/`. To change the IP range, edit the `addresses`
field and push to `main`. Flux applies the change automatically.

