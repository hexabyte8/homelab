# AdGuard Home

This document covers the AdGuard Home deployment in this homelab — what it does, how it is provisioned, and how to configure tailnet devices to use it as their DNS resolver.

---

## Overview

[AdGuard Home](https://adguard.com/en/adguard-home/overview.html) is a network-wide DNS ad and tracker blocker that runs as a self-hosted resolver.  It provides:

- **DNS-level ad blocking** — blocks ads, trackers, and malware domains before they even load
- **Query log** — full visibility into every DNS query made by any tailnet device
- **Custom filtering rules** — per-device allow/deny lists and rewrite rules
- **Upstream DNS over HTTPS** — forwards unblocked queries over encrypted DoH

AdGuard Home is exposed to both the tailnet and the local LAN:

- **Web UI** → `https://adguard.tailnet.ts.net` — Tailscale Ingress, `prod` ProxyClass (no Funnel, tailnet only)
- **DNS (port 53, tailnet)** → `adguard-dns.tailnet.ts.net` / `<adguard-ts-ip>` — Tailscale LoadBalancer Service
- **DNS (port 53, LAN)** → `<adguard-lan-ip>` — MetalLB LoadBalancer Service

No port is exposed to the public internet. The web UI is tailnet-only; DNS is reachable from both tailnet and LAN devices.

---

## Architecture

| Component | Detail |
|---|---|
| **Runtime** | Kubernetes Deployment in the `adguard` namespace |
| **Image** | `adguard/adguardhome:v0.107.63` |
| **Web UI** | Tailscale Ingress (`prod` ProxyClass) → `https://adguard.tailnet.ts.net` |
| **DNS (tailnet)** | Tailscale LoadBalancer Service → `adguard-dns.tailnet.ts.net:53` / `<adguard-ts-ip>` (UDP + TCP) |
| **DNS (LAN)** | MetalLB LoadBalancer Service → `<adguard-lan-ip>:53` (UDP + TCP) |
| **Config storage** | Longhorn PVC `adguard-conf` (1 Gi) — mounted at `/opt/adguardhome/conf` |
| **Data storage** | Longhorn PVC `adguard-work` (5 Gi) — mounted at `/opt/adguardhome/work` |
| **Provisioning** | Flux CD — managed via `k3s/manifests/adguard/` and `k3s/flux/apps/adguard.yaml` |

### Why tailnet-only for the web UI?

The Tailscale Ingress uses the `prod` ProxyClass (not `funnel`) so the web UI is only reachable from devices on the `your-tailnet` tailnet. The DNS LoadBalancer services use two separate services — one with `loadBalancerClass: tailscale` (Tailscale operator, tailnet-only) and one without a class (MetalLB, LAN) — so port 53 is available to both tailnet and LAN devices but never forwarded to the public internet.

### File layout

```
k3s/manifests/adguard/
├── deployment.yaml      # AdGuard Home Deployment
├── service.yaml         # ClusterIP — web UI (port 3000) for internal routing
├── service-dns.yaml     # LoadBalancer (Tailscale) — DNS (port 53 TCP + UDP, tailnet)
├── service-dns-lan.yaml # LoadBalancer (MetalLB) — DNS (port 53 TCP + UDP, LAN)
├── ingress.yaml         # Tailscale Ingress — web UI (HTTPS, tailnet-only)
└── pvc.yaml             # Longhorn PVCs for conf + work directories

k3s/flux/apps/adguard.yaml   # Flux Kustomization
```

---

## Deploying AdGuard Home

AdGuard Home is managed by Flux CD via a Kustomization pointing at `k3s/manifests/adguard/`. No manual deploy steps are required after the manifests are committed — Flux reconciles within ~10 minutes (or immediately with `flux reconcile kustomization adguard -n flux-system`).

### Triggering a deploy

Commit and push to `main`. Flux detects the change and applies it automatically:

```bash
git push origin main
# Flux reconciles within ~10 minutes; force immediately:
flux reconcile kustomization adguard -n flux-system
```

Watch progress via kubectl:

```bash
kubectl get kustomization adguard -n flux-system
kubectl get pods -n adguard
kubectl get ingress -n adguard
kubectl get svc -n adguard
```

---

## First-Run Setup

On first deploy, AdGuard Home detects no config in the PVC and starts its **first-run setup wizard** on port 3000.  The wizard is accessible over the tailnet only (via the Tailscale Ingress).

### Step 1 — Open the setup wizard

Navigate to **<https://adguard.tailnet.ts.net>** from any device on the tailnet.

!!! note "Initial readiness"
    The wizard starts listening on port 3000 immediately, but the pod readiness probe passes only after port 3000 is responding.  If the wizard page doesn't load within 60 seconds, check pod logs:
    ```bash
    kubectl logs -n adguard -l app=adguard-home
    ```

### Step 2 — Admin web interface port

When asked for the **Admin Web Interface** listen port, leave it at the default **3000**.

!!! warning "Do not change the web UI port to 443"
    The Kubernetes liveness and readiness probes check port 3000. Setting the web UI to
    port 443 causes the probes to fail, putting the pod into a crash loop. The Tailscale
    Ingress handles HTTPS termination externally — AdGuard only needs plain HTTP on 3000
    internally. See the [troubleshooting guide](troubleshooting/adguard-web-ui-port-crash-loop.md)
    if you have already set it to 443.

### Step 3 — Admin credentials

Set a strong admin username and password.  Store the password in your password manager.

### Step 4 — DNS listening interface

When asked *"DNS server listen interface"*, choose **All interfaces** (or `0.0.0.0`), and leave the port at **53**.

> The pod's network is isolated inside the cluster. External DNS traffic reaches AdGuard only via the two LoadBalancer Services, so selecting *All interfaces* does **not** expose port 53 beyond what those services advertise.

### Step 5 — Confirm and finish

Complete the wizard.  AdGuard Home saves its config to the Longhorn PVC and restarts into normal operation.

---

## Configuring Devices to Use AdGuard Home

### Tailnet devices

Once AdGuard Home is running, find the DNS Tailscale IP:

```bash
# From any tailnet device
tailscale status | grep adguard-dns
# e.g. <adguard-ts-ip>  adguard-dns  linux  -
```

#### Method A — Per-device DNS (testing / selective)

Set the DNS server on a single device to the IP shown above.

#### Method B — Tailscale DNS override (all tailnet devices)

In the Tailscale admin console:

1. Go to <https://login.tailscale.com/admin/dns>
2. Under **Nameservers → Add nameserver → Custom**, enter the Tailscale IP of `adguard-dns`
3. Enable **Override local DNS** to force all tailnet devices through AdGuard Home

!!! tip
    Tailscale's DNS override applies to devices when they are connected to the tailnet.  AdGuard Home forwards unblocked queries upstream using its own configured resolvers, so tailnet devices do not need to reach the public resolvers directly.

### LAN devices

Point any device on the local network at `<adguard-lan-ip>` as its DNS server. No Tailscale required. This works for:

- Router-level DNS (set in your router's DHCP config to push `<adguard-lan-ip>` to all LAN clients automatically)
- Individual devices (set manually in network settings)

```bash
# Quick test from any LAN device
dig @<adguard-lan-ip> google.com
```

---

## Updating AdGuard Home

The image version is pinned in `k3s/manifests/adguard/deployment.yaml`.  To upgrade:

1. Update the `image` tag in `deployment.yaml`
2. Commit and push — Flux rolls out the new version automatically

```bash
# deployment.yaml
image: adguard/adguardhome:v0.108.0   # bump to the desired version
```

---

## Useful Commands

```bash
# Check pod status
kubectl get pods -n adguard

# Follow pod logs
kubectl logs -n adguard -l app=adguard-home -f

# Check Tailscale DNS service (tailnet IP)
kubectl get svc adguard-dns -n adguard

# Check MetalLB DNS service (LAN IP)
kubectl get svc adguard-dns-lan -n adguard

# Check Tailscale Ingress for web UI
kubectl get ingress adguard-home -n adguard

# Force Flux to re-reconcile
flux reconcile kustomization adguard -n flux-system
```

---

## Troubleshooting

### Pod in crash loop — web UI port misconfigured

If AdGuard was set up with the web UI on port 443 via the setup wizard, the pod enters a
crash loop because Kubernetes probes expect port 3000. See the dedicated guide:
[AdGuard web UI port crash loop](troubleshooting/adguard-web-ui-port-crash-loop.md).

### Web UI not reachable

1. Verify you are connected to the tailnet: `tailscale status`
2. Check the Tailscale proxy pod for the Ingress:
   ```bash
   kubectl get pods -n tailscale | grep adguard
   kubectl logs -n tailscale <ts-adguard-home-...>
   ```
3. Confirm the Ingress got a Tailscale address:
   ```bash
   kubectl get ingress adguard-home -n adguard
   # ADDRESS column should show a Tailscale IP
   ```

### DNS queries not resolving

1. Find the DNS service's Tailscale IP:
   ```bash
   kubectl get svc adguard-dns -n adguard
   # EXTERNAL-IP column shows the Tailscale IP
   ```
2. Test from a tailnet device:
   ```bash
   dig @<tailscale-ip> google.com
   ```
3. Confirm the proxy pod is running:
   ```bash
   kubectl get pods -n tailscale | grep adguard-dns
   ```

### Pod stuck in Pending / PVC not bound

```bash
kubectl describe pvc adguard-conf -n adguard
kubectl describe pvc adguard-work -n adguard
# Check Longhorn is healthy
kubectl get pods -n longhorn-system
```

### Config lost after pod restart

The PVCs are backed by Longhorn.  If the config resets to the wizard, the PVC may have been recreated (e.g., after a `kubectl delete namespace adguard`).  Restore from a Longhorn snapshot if available, or re-run the setup wizard.

---

## Reference

| Item | Value |
|---|---|
| Web UI (tailnet only) | `https://adguard.tailnet.ts.net` |
| DNS hostname (tailnet) | `adguard-dns.tailnet.ts.net` / `<adguard-ts-ip>` |
| DNS IP (LAN) | `<adguard-lan-ip>` |
| Namespace | `adguard` |
| Docker image | `adguard/adguardhome:v0.107.63` |
| Config PVC | `adguard-conf` (1 Gi, Longhorn) |
| Data PVC | `adguard-work` (5 Gi, Longhorn) |
| Flux Kustomization | `adguard` (namespace `flux-system`) |
| Manifests | `k3s/manifests/adguard/` |
| Flux app file | `k3s/flux/apps/adguard.yaml` |

**See also:**

- [tailscale-operator.md](tailscale-operator.md) — Tailscale Ingress and LoadBalancer patterns
- [gitops-flux.md](gitops-flux.md) — Flux CD reconciliation, adding new services
- [manifests-and-helm.md](manifests-and-helm.md) — full manifest reference
