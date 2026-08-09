# Homelab Documentation

Welcome to my homelab docs. This covers the k3s cluster running on a self-hosted
Proxmox server, managed via GitOps with Flux CD.

## Cluster overview

| Component   | Details                                                                               |
| ----------- | ------------------------------------------------------------------------------------- |
| Hypervisor  | Proxmox                                                                               |
| k3s version | v1.34.x                                                                               |
| Nodes       | 1 server + 2 agents                                                                   |
| Networking  | Flannel (VXLAN) + Tailscale operator                                                  |
| Storage     | Longhorn (distributed)                                                                |
| GitOps      | Flux CD                                                                               |
| Ingress     | Traefik (Cloudflare Tunnel `*.example.com`) + Tailscale operator (`*.daggertooth-scala.ts.net`) |
| TLS         | cert-manager + Let's Encrypt (Cloudflare path); Tailscale (Tailscale path)            |

## Guides

- **[GitOps with Flux CD](gitops-flux.md)** - Bootstrap, adding services, patched secrets
- **[Adding a New Service](new-service.md)** - End-to-end guide: manifests → Flux → ingress → Authentik
- **[Cloudflare Tunnels](cloudflare-tunnels.md)** - Public ingress via Cloudflare Tunnel
- **[Tailscale Operator](tailscale-operator.md)** - Exposing services on the tailnet
- **[Flannel over Tailscale](flannel-over-tailscale.md)** - Cross-node pod networking via Tailscale IPs
- **[Manifests & Helm](manifests-and-helm.md)** - Cluster overview and manual `kubectl` / `helm` escape hatches
- **[Monitoring](monitoring.md)** - Prometheus, Grafana, and alerting
- **[Disaster Recovery](disaster-recovery/index.md)** - Full rebuild from scratch
- **[Fail2ban](fail2ban.md)** - DaemonSet deployment, jail config, ban management, troubleshooting
