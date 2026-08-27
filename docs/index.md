# GitOps Homelab Documentation

Welcome to my homelab docs. This covers the k3s cluster running on a self-hosted
Proxmox server, managed via GitOps with Flux CD.

## Cluster overview

| Component   | Details                                                                                         |
| ----------- | ----------------------------------------------------------------------------------------------- |
| Hypervisor  | Proxmox                                                                                         |
| k3s version | v1.34.x                                                                                         |
| Nodes       | 1 server + 2 agents                                                                             |
| Networking  | Flannel (VXLAN) + Tailscale operator                                                            |
| Storage     | Longhorn (distributed)                                                                          |
| GitOps      | Flux CD                                                                                         |
| Ingress     | Traefik (Cloudflare Tunnel `*.example.com`) + Tailscale operator (`*.daggertooth-scala.ts.net`) |
| TLS         | cert-manager + Let's Encrypt (Cloudflare path); Tailscale (Tailscale path)                      |
