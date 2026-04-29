# Homelab Documentation

Welcome to my homelab docs. This covers the k3s cluster running on a self-hosted
Proxmox server, managed via GitOps with Flux CD.

## Cluster overview

| Component   | Details                                         |
| ----------- | ----------------------------------------------- |
| Hypervisor  | Proxmox                                         |
| k3s version | v1.34.x                                         |
| Nodes       | 1 server + 2 agents                             |
| Networking  | Flannel (VXLAN) + Tailscale operator            |
| Storage     | Longhorn (distributed)                          |
| GitOps      | Flux CD                                         |
| Ingress     | Tailscale (`*.tailnet.ts.net`) and Cloudflare Tunnel (`*.example.com`) |
| TLS         | cert-manager + Let's Encrypt (Cloudflare path); Tailscale (Tailscale path) |

## Key services

| Service | URL | Notes |
| --- | --- | --- |
| Authentik | `authentik.tailnet.ts.net` | SSO / identity provider |
| AdGuard Home | `adguard.tailnet.ts.net` | DNS ad-blocking |
| Dashy | `dashy.tailnet.ts.net` | Service dashboard |
| Uptime Kuma | `uptime-kuma.tailnet.ts.net` · `uptime.example.com` (public) | Uptime monitoring |
| Jellyfin | `jellyfin.tailnet.ts.net` · `jellyfin.example.com` (public) | Media server |
| FileBrowser | `jellyfin-files.tailnet.ts.net` | Web file manager |
| Transmission | `jellyfin-transmission.tailnet.ts.net` | BitTorrent client |
| Metube | `jellyfin-ytdl.tailnet.ts.net` | YouTube downloader |
| Calibre-Web | `calibre-web.tailnet.ts.net` · `calibre.example.com` (public) | Ebook library |
| Stalwart Mail | `mail.tailnet.ts.net` · `mail.example.com` (public) | Mail server |
| Ntfy | `ntfy.tailnet.ts.net` | Push notifications |
| Docs (this site) | `docs.tailnet.ts.net` · `docs.example.com` (public, Authentik SSO) | Documentation |
| Fail2ban | — | DaemonSet on all nodes — managed via [Ansible](fail2ban.md) |

## Guides

- **[GitOps with Flux CD](gitops-flux.md)** — Bootstrap, adding services, patched secrets
- **[Adding a New Service](new-service.md)** — End-to-end guide: manifests → Flux → ingress → Authentik
- **[Tailscale Operator](tailscale-operator.md)** — Exposing services on the tailnet
- **[Flannel over Tailscale](flannel-over-tailscale.md)** — Cross-node pod networking via Tailscale IPs
- **[Manifests & Helm](manifests-and-helm.md)** — Cluster overview and manual `kubectl` / `helm` escape hatches
- **[Disaster Recovery](disaster-recovery/index.md)** — Full rebuild from scratch
- **[Fail2ban](fail2ban.md)** — DaemonSet deployment, jail config, ban management, troubleshooting

## Authentik & Identity

Authentik manages all SSO, OIDC, LDAP, and ForwardAuth for this cluster. Its configuration
(flows, providers, applications, outposts) is managed declaratively via OpenTofu IaC in
`opentofu/authentik*.tf`. New users are onboarded via an invitation workflow
(`.github/workflows/authentik-invite.yml`) that emails a single-use enrollment link.

See [authentik.md](authentik.md) for the full architecture, IaC structure, and invitation process.

## Troubleshooting

- **[Tailscale Proxy Performance (MTU)](troubleshooting/tailscale-proxy-mtu-performance.md)**
- **[Tailscale Proxy Pod Stuck Terminating](troubleshooting/tailscale-proxy-pod-stuck-terminating.md)**
- **[AdGuard Web UI Port Crash Loop](troubleshooting/adguard-web-ui-port-crash-loop.md)**
- **[Non-root Container PVC Permissions](troubleshooting/non-root-container-pvc-permissions.md)**
