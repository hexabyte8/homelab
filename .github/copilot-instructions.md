# Copilot Instructions

## Repository overview

This is a GitOps-driven homelab built around a k3s cluster on Proxmox. All
infrastructure (DNS, VMs, ACLs, cluster workloads) is defined as code in this
repository and applied via GitHub Actions and Flux CD. See `README.md` for the
full architecture description.

---

## MCP servers

The Copilot cloud agent has access to the following MCP servers. They are
reachable over the private Tailscale network (tailnet); the
`copilot-setup-steps.yml` workflow joins the runner to the tailnet before every
session, so the endpoints are available by the time the agent starts.

### kubernetes — live cluster access

| Property | Value |
|---|---|
| Transport | HTTP (Streamable HTTP / SSE) |
| URL | `https://mcp-kubernetes.daggertooth-scala.ts.net/mcp` |
| Auth | None — presence on the tailnet is the credential |
| Port | 443 (Tailscale Ingress → cluster Service on 8000) |

**What it provides:** tools to inspect and manage the k3s cluster — list/get/
describe Kubernetes resources, read pod logs, apply manifests, etc.

**When to use it:** whenever a task requires knowledge of live cluster state
(e.g. "what pods are running in the `jellyfin` namespace?", "show me the
current image tag for the `traefik` deployment", "apply this manifest").

**How to call it:** use the `kubernetes` MCP server name exactly as configured.
No `Authorization` header is needed.

---

## Networking context

- The runner joins the tailnet as `tag:copilot` via the OAuth client stored in
  Bitwarden (secret `BW_ACCESS_TOKEN`, available in the `copilot` Actions
  environment).
- The ACL grants `tag:copilot → tag:k8s-operator` on `tcp:443` only. The agent
  cannot SSH to servers or reach any other tailnet node.
- MagicDNS is enabled (`tailscale set --accept-dns=true`) so the hostname
  `mcp-kubernetes.daggertooth-scala.ts.net` resolves correctly inside the runner.

---

## Repository conventions

- **Secrets** — no real credentials are committed. Kubernetes Secret manifests
  contain `REPLACE_ME` placeholders patched at deploy time by
  `k3s-patch-secrets.yml`. Never commit real secrets.
- **GitOps** — cluster changes go through `k3s/` and are reconciled by Flux CD.
  Infrastructure changes go through `opentofu/` and `ansible/`. Do not suggest
  `kubectl apply` as part of a normal change; open a PR instead.
- **IaC layout** — `opentofu/<provider>/` contains one root module per provider
  (cloudflare, proxmox, tailscale, authentik, aws). Each module is applied
  independently via the reusable `opentofu-reusable.yml` workflow.
- **Flux** — `k3s/flux/apps/` contains one Kustomization or HelmRelease per
  service. Adding a new workload means adding a directory there plus the
  manifests under `k3s/manifests/<service>/`.
