# Phase 5 — Flux Bootstrap

> **Time estimate:** ~10 minutes
>
> **Prerequisites:** k3s cluster is running (all 3 nodes `Ready` from Phase 4), `kubectl` configured locally, `flux` CLI installed

---

## What is Flux?

Flux CD is a **GitOps controller** — it continuously watches this GitHub repository and automatically applies any Kubernetes manifests or Helm charts it finds to the cluster. When you push code changes to `main`, Flux detects them within ~1 minute and reconciles the cluster to match.

Flux runs as a set of 4 controllers in the `flux-system` namespace:
- **source-controller** — periodically polls the GitHub repo for updates
- **kustomize-controller** — renders and applies Kustomization objects
- **helm-controller** — manages Helm chart releases
- **notification-controller** — sends alerts (Slack, Webhook, etc.)

**Bootstrapping** Flux is a one-time setup that installs these controllers and provisions an SSH deploy key for read-only access to the repo.

---

## Prerequisites Checklist

Before running bootstrap:

- [ ] All 3 k3s nodes are `Ready` (verify: `kubectl get nodes`)
- [ ] `flux` CLI installed locally (`brew install fluxcd/tap/flux` or `curl -s https://fluxcd.io/install.sh | sudo bash`)
- [ ] GitHub PAT created with `repo` scope (settings → Developer settings → Personal access tokens → Generate new token)
- [ ] Export it as `GITHUB_TOKEN` in your terminal: `export GITHUB_TOKEN=ghp_...`
- [ ] `kubectl` is configured to access the k3s cluster

---

## Step 1: Install the Flux CLI

If not already installed:

```bash
# Official Flux install script
curl -s https://fluxcd.io/install.sh | sudo bash
```

**Verify:**
```bash
flux version
# Expected output: flux: v2.x.x, etc.
```

---

## Step 2: Run Flux Bootstrap

Export your GitHub PAT and bootstrap:

```bash
export GITHUB_TOKEN=<your-github-pat-with-repo-scope>

flux bootstrap github \
  --owner=hexabyte8 \
  --repository=homelab \
  --branch=main \
  --path=k3s/flux/clusters/k3s \
  --personal
```

**What this does:**

1. Creates the `flux-system` namespace
2. Installs the 4 Flux controllers (source, kustomize, helm, notification)
3. Generates an SSH deploy key on the GitHub repo with read-only access
4. Stores the deploy key private half as a `Secret` in `flux-system`
5. Creates a `GitRepository` resource pointing to `https://github.com/hexabyte8/homelab`
6. Creates a root `Kustomization` resource that reconciles `k3s/flux/clusters/k3s/`
7. Commits the bootstrap manifests (`gotk-components.yaml`, `gotk-sync.yaml`) to the repo

**Expected output:**
```
► connecting to github.com
✓ bootstrapping cluster
► cloning branch "main" from Git repository "https://github.com/hexabyte8/homelab.git"
✓ cloned repository
► generating component manifests
✓ generated components
► installing components in flux-system namespace
...
✓ bootstrap completed
```

---

## Step 3: Wait for System Reconciliation

After bootstrap, wait for the core Flux components to be ready:

```bash
# Watch the Flux system namespace
kubectl get pods -n flux-system -w

# Press Ctrl+C once all pods show Running
```

Within ~2 minutes, the root `apps` Kustomization will reconcile and apply all per-service manifests and Helm charts from `k3s/flux/apps/`.

---

## Step 4: Verify Reconciliation

Check that Flux Kustomizations and HelmReleases have begun reconciling:

```bash
# All system Kustomizations/HelmReleases (should show Ready=True)
flux get kustomizations -A
flux get helmreleases -A
```

**Expected output for system components:**
```
NAMESPACE     NAME                  READY   MESSAGE
flux-system   flux-system           True    update succeeded
flux-system   apps                  True    update succeeded
kube-system   traefik-config        True    update succeeded
authentik     authentik-config      True    update succeeded
cert-manager  cert-manager-config   True    update succeeded
...
```

**Expected output for app workloads (these will show `False` or `Stalled` — this is normal):**

Workloads that depend on secrets (Authentik, Cloudflared, Tailscale operator, Stalwart) will show:
```
NAMESPACE   NAME        READY   MESSAGE
authentik   authentik   False   (patching secret in progress)
cloudflared cloudflared False   (waiting for secret: tunnel-token)
tailscale   tailscale   False   (waiting for secret: oauth credentials)
...
```

This is **expected and normal** — Phase 6 will patch the real secrets from Bitwarden, allowing workloads to start.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bootstrap hangs at "installing components" | Ensure `kubectl` can reach the cluster: `kubectl cluster-info` |
| `Kustomization` shows `False` with error | Check: `flux describe kustomization <name> -n <namespace>` and `flux logs --kind=Kustomization --all-namespaces` |
| Workload pods stuck in `Pending` | This is expected — secrets not yet patched. Proceed to Phase 6. |
| Deploy key not created on GitHub | Verify your PAT has `repo` scope and is exported as `GITHUB_TOKEN` before bootstrap |

**View live Flux logs:**
```bash
flux logs --all-namespaces --follow --since=5m
```

---

## Summary Checklist

Before proceeding to Phase 6:

- [ ] `flux bootstrap github` command completed without errors
- [ ] All `flux-system` pods show `Running` status
- [ ] `flux get kustomizations -A` shows system items as `Ready=True`
- [ ] `flux get helmreleases -A` shows system items as `Ready=True`
- [ ] App workloads (Authentik, Cloudflared, etc.) show `False`/`Stalled` (expected — secrets not yet patched)
- [ ] Deploy key is visible on the GitHub repo (Settings → Deploy keys)

---

## Notes

- The token in `GITHUB_TOKEN` can be revoked immediately after bootstrap completes — Flux uses the deploy key from that point onward.
- Flux reconciles every 10 minutes by default. To force immediate reconciliation: `flux reconcile source git flux-system`
- For detailed Flux operations, GitOps architecture, and advanced troubleshooting, see [`docs/gitops-flux.md`](../gitops-flux.md).

---

## Proceed to Phase 6

→ [Phase 6: Secrets Restore](./06-secrets-restore.md)
