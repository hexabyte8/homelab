# Flux CD & GitOps

This homelab uses [Flux CD](https://fluxcd.io/) as its GitOps engine. Flux
runs four controllers in the `flux-system` namespace:

| Controller | Purpose |
|---|---|
| `source-controller` | Polls the Git repository and Helm repos |
| `kustomize-controller` | Reconciles `Kustomization` resources |
| `helm-controller` | Reconciles `HelmRelease` resources |
| `notification-controller` | Optional alerts via webhook / Slack / etc. |

The cluster is bootstrapped from `k3s/flux/clusters/k3s/`, which contains
the root `flux-system` `Kustomization` plus `apps.yaml` (the root apps Kustomization)
and `sources.yaml` (`HelmRepository` declarations).
Per-app definitions live under `k3s/flux/apps/`.

For the full bootstrap procedure, per-service onboarding recipe and
troubleshooting tips, see [`gitops-flux.md`](../../gitops-flux.md).
