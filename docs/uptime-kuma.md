# Uptime Kuma

[Uptime Kuma](https://github.com/louislam/uptime-kuma) is a self-hosted monitoring dashboard. It polls configured endpoints (HTTP, TCP, DNS, ping, etc.) at regular intervals and displays their uptime history, response times, and current status.

## Access

| Path | URL | Audience |
|------|-----|----------|
| Admin (tailnet) | `https://uptime-kuma.tailnet.ts.net` | Tailnet members |
| Public status page | `https://uptime.example.com` | Anyone (Authentik SSO required) |

The **Tailscale Funnel** ingress serves as the admin interface — full access to add/edit monitors, manage notifications, etc. The **Cloudflare Tunnel** ingress exposes a read-only-style public status page protected by Authentik ForwardAuth.

## Architecture

```
Tailnet member → Tailscale Funnel → Uptime Kuma (port 3001)
                                          ↓
Internet → Cloudflare Edge → cloudflared → Traefik
                                           → cloudflare-https-scheme (middleware)
                                           → Authentik ForwardAuth (middleware)
                                           → Uptime Kuma (port 3001)
                                                ↓
                                          Longhorn PVC (uptime-kuma-data)
```

| Component | Image | Purpose |
|-----------|-------|---------|
| Uptime Kuma | `louislam/uptime-kuma:1` (`imagePullPolicy: Always`) | Monitoring dashboard |

### Ingress details

**Tailscale (admin):**
- `ingressClassName: tailscale`
- Annotations: `tailscale.com/proxy-class: funnel`, `tailscale.com/funnel: "true"`
- TLS handled by Tailscale — no cert-manager needed

**Cloudflare Tunnel (public):**
- `ingressClassName: traefik`
- Host: `uptime.example.com`
- Middleware chain: `kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd`
- TLS terminated at Cloudflare edge — no `tls:` block or cert-manager annotation required on this ingress

## Storage

| PVC | Size | Mount | Contents |
|-----|------|-------|----------|
| `uptime-kuma-data` | 1Gi | `/app/data` | SQLite database, monitor config, uptime history |

All monitor definitions, notification channels, and uptime history are stored in a SQLite database at `/app/data/kuma.db`.

## Environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `UPTIME_KUMA_DISABLE_AUTH` | `1` | Disables Uptime Kuma's built-in login screen |

Built-in auth is disabled because access is controlled at the network level:
- Admin path → Tailscale (tailnet membership required)
- Public path → Authentik ForwardAuth (SSO login required before Traefik forwards the request)

## Authentik SSO (public path)

The Cloudflare Tunnel ingress has the Authentik ForwardAuth middleware chain applied. Any request to `https://uptime.example.com` is intercepted by Traefik and forwarded to Authentik for authentication before being passed to Uptime Kuma.

**Middleware order is critical.** The `cloudflare-https-scheme` middleware must run **before** `authentik-forward-auth`:

```
kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd
```

`cloudflared` connects to Traefik over plain HTTP, which causes Traefik to set `X-Forwarded-Proto: http`. Authentik uses this header to build the OIDC callback URL — if it says `http`, the auth flow fails with a 400 error. The `cloudflare-https-scheme` middleware rewrites the header to `https` before ForwardAuth runs.

See [cloudflare-tunnels.md](cloudflare-tunnels.md) for full background and [authentik.md](authentik.md) for the Authentik UI setup steps.

### Authentik UI steps

Three steps are required in the Authentik web UI to protect Uptime Kuma:

1. **Create a Proxy Provider** — Applications → Providers → Create → Proxy Provider
   - Mode: `Forward auth (single application)`
   - External Host: `https://uptime.example.com`

2. **Create an Application** — Applications → Applications → Create
   - Link to the provider above
   - Launch URL: `https://uptime.example.com`

3. **Assign to the Embedded Outpost** — Applications → Outposts → Edit `authentik Embedded Outpost`
   - Move the Uptime Kuma application to the Selected list and save

## Adding a new monitor

1. Log in via the Tailscale URL: `https://uptime-kuma.tailnet.ts.net`
2. Click **Add New Monitor**
3. Choose monitor type:
   - **HTTP(s)** — polls a URL; verifies status code and optionally response body
   - **TCP Port** — checks a TCP port is open
   - **Ping** — ICMP ping
   - **DNS** — verifies DNS resolution
4. Set the **Heartbeat Interval** (default 60s) and **Retries** before marking down
5. Optionally assign a **Notification channel** (e.g. ntfy — see below)
6. Click **Save**

### Ntfy integration

Uptime Kuma can publish alerts to the [ntfy](ntfy.md) instance. Configure a notification channel in Settings → Notifications:

- Type: **ntfy**
- Server URL: `http://ntfy.ntfy.svc.cluster.local` (ClusterIP — stays in-cluster)
- Topic: e.g. `homelab-alerts`

Using the ClusterIP URL ensures alert delivery even if Tailscale is temporarily unavailable.

## Upgrading

Uptime Kuma uses `imagePullPolicy: Always` with the `1` (major-pinned) tag. To pull the latest `1.x` release:

```bash
kubectl rollout restart deployment/uptime-kuma -n uptime-kuma
```

For major version upgrades, update the tag in `k3s/manifests/uptime-kuma/deployment.yaml` and review the [Uptime Kuma release notes](https://github.com/louislam/uptime-kuma/releases) for breaking changes before committing.

## Troubleshooting

### Public URL redirects to Authentik login loop (400 error)

Verify the middleware order in the Cloudflare ingress annotation — `cloudflare-https-scheme` must come first:

```bash
kubectl get ingress uptime-kuma-cloudflare -n uptime-kuma -o yaml | grep middlewares
```

Expected:
```
kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd
```

### Monitor data lost after pod restart

If the PVC is healthy, data should persist across restarts. Check the PVC:

```bash
kubectl get pvc uptime-kuma-data -n uptime-kuma
kubectl exec deployment/uptime-kuma -n uptime-kuma -- ls -lh /app/data/
```

### Pod not starting

```bash
kubectl describe pod -l app=uptime-kuma -n uptime-kuma
kubectl logs deployment/uptime-kuma -n uptime-kuma
```

Check that the `uptime-kuma-data` PVC is bound — a `Pending` PVC will block the pod indefinitely.
