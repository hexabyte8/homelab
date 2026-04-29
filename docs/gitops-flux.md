# GitOps with Flux CD

This cluster is GitOps-managed by **Flux CD** — full stop. All Kubernetes workloads
and Helm releases are reconciled from this repository. There is no other GitOps
controller; ArgoCD was removed when the migration to Flux was completed.

---

## Repository Layout

```
k3s/flux/
├── clusters/k3s/
│   ├── flux-system/         # populated by `flux bootstrap` (gotk-components, gotk-sync)
│   ├── apps.yaml            # root Flux Kustomization → ../../apps
│   └── sources.yaml         # HelmRepositories used by HelmReleases
└── apps/
    ├── kustomization.yaml   # bundle of every active per-service file
    ├── namespaces.yaml      # Namespace objects for plain-manifest services
    ├── cert-manager.yaml         # HelmRelease (operator)
    ├── cert-manager-config.yaml  # Kustomization (config; dependsOn: cert-manager)
    ├── cnpg-operator.yaml
    ├── longhorn-operator.yaml
    ├── longhorn-config.yaml
    ├── tailscale-operator.yaml
    ├── tailscale-config.yaml
    ├── authentik.yaml
    ├── authentik-config.yaml
    ├── traefik-config.yaml
    ├── cloudflared.yaml
    ├── metallb-config.yaml
    ├── stalwart.yaml        # dependsOn: cnpg-operator
    └── <other workloads>.yaml
```

`k3s/flux/clusters/k3s/apps.yaml` is the **root Kustomization** — Flux's equivalent of
an "App-of-Apps". It reconciles everything under `k3s/flux/apps/`, which in turn renders
every per-service `Kustomization` and `HelmRelease` listed in `kustomization.yaml`.

Plain-manifest services point at `k3s/manifests/<service>/` via `spec.path`. Helm-based
services reference a `HelmRepository` in `sources.yaml`.

---

## Bootstrap Procedure

Run **once** to install the four Flux controllers and connect them to this repo. The
cluster must be reachable via `kubectl`.

### Prerequisites

- `flux` CLI installed (`brew install fluxcd/tap/flux` or the upstream install script).
- A short-lived GitHub personal access token with `repo` scope, exported as
  `GITHUB_TOKEN`. Flux only needs the token for the initial bootstrap; it then
  provisions a deploy key on the repo and stores its private half as a `Secret`.
  After bootstrap the token can be revoked.

### Run bootstrap

```bash
export GITHUB_TOKEN=<your-token>

flux bootstrap github \
  --owner=hexabyte8 \
  --repository=homelab \
  --branch=main \
  --path=k3s/flux/clusters/k3s \
  --personal
```

This:

1. Installs the four controllers (`source`, `kustomize`, `helm`, `notification`) in the
   `flux-system` namespace.
2. Creates a deploy key on the GitHub repo and stores its private half as the
   `flux-system` Secret in `flux-system`.
3. Commits `gotk-components.yaml`, `gotk-sync.yaml`, and `kustomization.yaml` to
   `k3s/flux/clusters/k3s/flux-system/`.
4. Creates the root `flux-system` `GitRepository` and `Kustomization` that reconciles
   everything in `k3s/flux/clusters/k3s/`.

Within ~1 minute the root `apps` Kustomization applies, creating every per-service
`Kustomization` and `HelmRelease`. Workloads start as soon as their secrets are patched
(see Phase 6 of the disaster-recovery runbook).

### Verify

```bash
flux get kustomizations -A
flux get helmreleases -A
flux logs --all-namespaces --since=10m
```

---

## Adding a New Service

This is the canonical recipe. For a full walkthrough including ingress options and
Authentik protection, see [new-service.md](new-service.md).

### Plain manifests

1. Create your manifests under `k3s/manifests/<my-app>/`.
2. If the namespace is not created elsewhere, add it to
   `k3s/flux/apps/namespaces.yaml`.
3. Create `k3s/flux/apps/<my-app>.yaml`:

   ```yaml
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: my-app
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
     path: ./k3s/manifests/my-app
     targetNamespace: my-app
     # dependsOn:
     #   - name: cert-manager
   ```

4. Add `- my-app.yaml` to the `resources:` list in
   `k3s/flux/apps/kustomization.yaml`.
5. Commit and push. Reconcile immediately with:

   ```bash
   flux reconcile kustomization apps -n flux-system
   ```

### Helm chart

1. If the chart repo is not in `k3s/flux/clusters/k3s/sources.yaml`, add a
   `HelmRepository` there.
2. Create `k3s/flux/apps/<my-app>.yaml`:

   ```yaml
   ---
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: my-app
     namespace: flux-system
   spec:
     interval: 30m
     releaseName: my-app
     targetNamespace: my-app
     install:
       createNamespace: true
     chart:
       spec:
         chart: my-chart
         version: 1.2.3
         sourceRef:
           kind: HelmRepository
           name: my-repo
           namespace: flux-system
     values:
       replicaCount: 1
   ```

3. Add it to `kustomization.yaml` and commit.

### Parking (disabling) a service

To temporarily disable a service without deleting its manifests, remove its entry from
`k3s/flux/apps/kustomization.yaml` and commit. Flux will prune the live resources on
the next reconciliation. There is no separate `apps-disabled/` directory — the
`kustomization.yaml` resource list is the single source of truth for what is active.

To re-enable, add the entry back and commit.

---

## Patched Secrets

Several `Secret` resources are committed to git with placeholder values (`REPLACE_ME`)
and are populated out-of-band by the `k3s-patch-secrets.yml` GitHub Actions workflow.
These secrets carry the annotation:

```yaml
kustomize.toolkit.fluxcd.io/reconcile: disabled
```

This tells `kustomize-controller` to **skip apply and prune** for that object. Flux
will never overwrite the live value with the placeholder from git.

!!! warning "Do not remove this annotation"
    Removing `kustomize.toolkit.fluxcd.io/reconcile: disabled` from a patched secret
    will cause Flux to reset its `/data` to the `REPLACE_ME` placeholder on the next
    reconciliation, breaking the corresponding workload.

The five secrets requiring this annotation today:

| Namespace     | Secret                           |
|---------------|----------------------------------|
| `authentik`   | `authentik-credentials`          |
| `cloudflared` | `cloudflared-tunnel-credentials` |
| `mcp-proxmox` | `mcp-proxmox-secrets`            |
| `stalwart`    | `stalwart-secrets`               |
| `tailscale`   | `operator-oauth`                 |

To patch a secret manually (use `kubectl patch`, not `kubectl apply`, to avoid
Server-Side Apply field-manager conflicts):

```bash
kubectl patch secret <name> -n <namespace> --type=merge \
  -p '{"stringData":{"key":"value"}}'
```

---

## Troubleshooting

| Problem | First thing to check |
|---------|----------------------|
| `Kustomization` is `False` | `flux describe kustomization <name>` and `flux logs --kind=Kustomization` |
| `HelmRelease` stuck in `Pending` | `flux describe helmrelease <name> -n flux-system`; usually a missing CRD or dependency |
| Drift not being reverted | Confirm the live resource does not carry `kustomize.toolkit.fluxcd.io/reconcile=disabled` |
| Source not updating | `flux reconcile source git flux-system` |
| New commit not picked up | Flux polls every 1 min by default; force with `flux reconcile source git flux-system` |

---

## Reference

| Resource | Value |
|---|---|
| Git repo | `https://github.com/hexabyte8/homelab` (deploy key) |
| Tracked branch | `main` |
| Bootstrap path | `k3s/flux/clusters/k3s` |
| Apps directory | `k3s/flux/apps` |
| Flux namespace | `flux-system` |
| Reconciliation interval (Kustomization) | 10 minutes |
| Reconciliation interval (HelmRelease) | 30 minutes |

**See also:**

- [new-service.md](new-service.md) — full end-to-end guide for adding a service (ingress, Authentik, Cloudflare Tunnel, Dashy tile)
- [disaster-recovery/05-flux-bootstrap.md](disaster-recovery/05-flux-bootstrap.md) — bootstrap in a disaster-recovery context
