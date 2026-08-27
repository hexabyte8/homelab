# GitOps Homelab

My GitOps-driven homelab infrastructure built around a small **k3s Kubernetes cluster on Proxmox**, with everything from VM provisioning to DNS records defined as code. This repository is published as a reference for others and as a public, auditable record of how the infrastructure is operated.

**REPO DISCLAIMER** - This is a personal lab. The architecture, conventions, and configuration choices are specific to my needs and preferences. This is not a copy/paste solution, but can be used as a reference for your own learning, or as a starting point for your own gitops journey.

**AI DISCLAIMER** - This repo was bootstrapped with the help of generative AI, a vast majority of the existing documentation content was written by AI.
This lab started in a private repo, and was made public to allow colleague to reference the cloudflare tunnel architecture to see how to manage applications without exposing ports to the public internet.
Over time I'll be doing some docs maintenance and refactoring by hand to correct or clarify AI generated documentation, as they may have minor inaccuracies, or expire quickly as the lab evolves.
I also leverage AI to assist with new deployments or config changes, you will see Copilot in the PR author in those cases for transparency.

---

## Tech stack

| Layer             | Technology                   | Why this one                                                           |
| ----------------- | ---------------------------- | ---------------------------------------------------------------------- |
| Virtualization    | Proxmox VE                   | Mature open-source hypervisor; clusterable; easy templating            |
| Kubernetes        | k3s (1 server + 2 agents)    | Lightweight, single-binary, ships sane defaults (Traefik, ServiceLB)   |
| GitOps            | Flux CD                      | Pure-Kubernetes-native, no UI process to operate, Kustomize/Helm-first |
| Ingress (private) | Tailscale Operator           | Tailnet-only services with automatic TLS via tsnet                     |
| Ingress (public)  | Traefik + Cloudflare Tunnel  | No port-forward on the home router; Cloudflare handles DDoS/edge TLS   |
| TLS               | cert-manager + Let's Encrypt | Automatic certificate issuance & rotation                              |
| Storage           | Longhorn                     | Replicated PVs, snapshots, S3 backup                                   |
| Auth / SSO        | Authentik                    | Self-hosted IdP with OIDC, LDAP, and Traefik ForwardAuth               |
| Databases         | CloudNativePG (CNPG)         | Operator-managed Postgres clusters per app                             |
| IaC               | OpenTofu                     | Cloudflare, Proxmox, Tailscale ACLs, Authentik, AWS S3                 |
| Secrets           | Bitwarden Secrets Manager    | Per-service-account access tokens, injected by `bitwarden/sm-action`   |
| CI/CD             | GitHub Actions               | Plan/apply for OpenTofu, Ansible playbook runners, secret patchers     |

---

## Security & sensitive data

Since this is a personal homelab repo, made public as a reference, please note:

- **No real secrets are committed.** All credentials, tokens, public IPs, and other sensitive info is injected into GitHub Actions at deploy time.

- **Kubernetes Secret manifests contain `REPLACE_ME` placeholders.** The [`k3s-patch-secrets`](.github/workflows/k3s-patch-secrets.yml) workflow patches the live values into the cluster after deploy, and the `kustomize.toolkit.fluxcd.io/reconcile: disabled` annotation prevents Flux from overwriting them.

As part of migrating a previously private repo to public, I did my best to scrub all sensitive data that the lab can run without being directly in code, leveraging Secrets Managers and sm operators in the cluster.

If something here looks like a leaked secret or you know of a way to omit some sensitive data within the GitOps design, please [open an issue](https://github.com/hexabyte8/homelab/issues).

---

## License & disclaimer

Provided as-is, without warranty. Configuration values, hostnames, and conventions are specific to this lab - copy with adaptation, not as-is. PRs that improve clarity for other readers are welcome.
