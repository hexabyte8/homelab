# Phase 5 — Flux Bootstrap

After the k3s cluster is up (Phase 4), bootstrap Flux to begin reconciling
all workload manifests from this repository.

See [`gitops-flux.md`](../gitops-flux.md) for the canonical Flux bootstrap
procedure. Summary:

```bash
export GITHUB_TOKEN=<short-lived PAT with repo scope>

flux bootstrap github \
  --owner=hexabyte8 \
  --repository=homelab \
  --branch=main \
  --path=k3s/flux/clusters/k3s \
  --personal
```

After bootstrap completes, verify all `Kustomization` and `HelmRelease`
objects reconcile to `Ready=True`:

```bash
flux get kustomizations -A
flux get helmreleases -A
```

The next phase ([Phase 6 — Secrets Restore](06-secrets-restore.md)) restores
the patched `Secret` values from Bitwarden so workloads can start.
