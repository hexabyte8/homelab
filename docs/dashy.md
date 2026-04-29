# Dashy — Service Dashboard

[Dashy](https://github.com/Lissy93/dashy) is the homelab's service dashboard. It is reachable two ways:

- **Tailnet (no auth)**: <https://dashy.tailnet.ts.net>
- **Public (Authentik ForwardAuth)**: <https://dashy.example.com>

It provides a visual overview of every service, with live status checks so you can see at a glance whether something is down.

---

## How It Works

### Config-as-code

Dashy's entire configuration — layout, sections, service entries, theme — lives in a single YAML file committed to this repository:

```
k3s/manifests/dashy/configmap.yaml
```

The file contains a Kubernetes ConfigMap whose `conf.yml` key is the raw Dashy configuration. Flux syncs this ConfigMap whenever it changes. The Deployment mounts it read-only at `/app/user-data/conf.yml` inside the Dashy pod.

```
GitHub PR merged → Flux syncs ConfigMap → pod restart picks up new config
```

### GitOps update flow

1. Edit `k3s/manifests/dashy/configmap.yaml`
2. Also bump the `kubectl.kubernetes.io/restartedAt` annotation in `k3s/manifests/dashy/deployment.yaml` to the current timestamp — this triggers a rolling restart when Flux applies the change
3. Commit both files together and push (or open a PR to `main`)
4. Flux picks up the changes within ~10 minutes and performs a rolling restart

!!! tip "Why bump the annotation?"
    Kubernetes does not restart a pod when only a ConfigMap changes. The `restartedAt` annotation on the Deployment pod template causes Flux to detect a diff and trigger a rolling restart. Without it, the new ConfigMap content is on disk but the running pod still serves the old config.

---

## Dashboard Structure

The `conf.yml` inside the ConfigMap is a standard [Dashy configuration file](https://dashy.to/docs/configuring). It has three top-level keys:

| Key | Purpose |
|---|---|
| `pageInfo` | Title, description, nav links |
| `appConfig` | Theme, layout, status check settings |
| `sections` | List of service groups, each containing `items` |

Each item in a section is one service tile:

```yaml
- title: My Service
  description: Short description shown under the title
  url: https://myservice.tailnet.ts.net
  icon: hl-myservice   # Homelab icon (see icon reference below)
  target: newtab       # Open in new tab
```

---

## Adding a New Service to the Dashboard

When you deploy a new service, add a corresponding tile to the Dashy config in the same PR.

**1. Open `k3s/manifests/dashy/configmap.yaml`**

Find the right section (or add a new one) under `sections:`. Add a new item:

```yaml
- title: My App
  description: What it does
  url: https://myapp.tailnet.ts.net
  icon: hl-myapp
  target: newtab
```

**2. Bump the restart annotation in `k3s/manifests/dashy/deployment.yaml`**

Update the timestamp in the pod template annotations:

```yaml
annotations:
  kubectl.kubernetes.io/restartedAt: "2026-04-01T12:00:00Z"  # ← set to current time
```

**3. Commit and push both files**

Flux will sync the ConfigMap and roll the Dashy pod within ~10 minutes.

---

## Modifying Existing Entries

Edit the relevant `items` entry in `k3s/manifests/dashy/configmap.yaml`. Bump the `restartedAt` annotation and push. Changes take effect after Flux reconciles.

---

## Adding a New Section

Add a new entry to the `sections` list:

```yaml
sections:
  # … existing sections …
  - name: My New Group
    icon: fas fa-puzzle-piece
    items:
      - title: Service One
        description: …
        url: https://…
        icon: hl-…
        target: newtab
```

Section icons use [Font Awesome 6](https://fontawesome.com/icons) class names (`fas fa-…`).

---

## Changing the Theme or Layout

The `appConfig` block controls global appearance:

```yaml
appConfig:
  theme: colorful          # built-in theme name — see https://dashy.to/docs/theming
  layout: auto             # auto | vertical | horizontal
  iconSize: medium         # small | medium | large
  statusCheck: true        # poll each URL and show up/down indicator
  statusCheckInterval: 300 # seconds between checks (300 = 5 min)
```

A full list of available themes is at <https://dashy.to/docs/theming>.

---

## Icon Reference

Dashy supports [Dashboard Icons](https://github.com/walkxcode/dashboard-icons) via the `hl-` prefix. For any service that has a Dashboard Icon, use `hl-<service-name>`. Examples:

| Service | Icon value |
|---|---|
| AdGuard Home | `hl-adguardhome` |
| Authentik | `hl-authentik` |
| Jellyfin | `hl-jellyfin` |
| Metube | `hl-metube` |
| Traefik | `hl-traefik` |
| Longhorn | `hl-longhorn` |
| Uptime Kuma | `hl-uptime-kuma` |
| FileBrowser | `hl-filebrowser` |
| Transmission | `hl-transmission` |
| Ntfy | `hl-ntfy` |

If there is no Dashboard Icon for a service, use a Font Awesome icon instead:

```yaml
icon: fas fa-server
```

Or a plain URL to any image:

```yaml
icon: https://example.com/logo.png
```

---

## Status Checks

With `appConfig.statusCheck: true`, Dashy polls the `url` of each tile and displays a green/red indicator. If a service is behind authentication (like Authentik ForwardAuth), the health check may return `401` or `302` and incorrectly show as down.

To fix this, override the status check URL with a public health endpoint if the service exposes one:

```yaml
- title: My App
  url: https://myapp.example.com
  statusCheckUrl: https://myapp.example.com/health
  statusCheckAcceptCodes: "200,401"  # treat 401 as healthy
```

See the [Dashy status check docs](https://dashy.to/docs/status-indicators) for the full list of options.

---

## Manifests Reference

| File | Purpose |
|---|---|
| `k3s/manifests/dashy/configmap.yaml` | **The dashboard configuration** — edit this to change anything visible |
| `k3s/manifests/dashy/deployment.yaml` | Dashy pod spec; bump `restartedAt` annotation when updating the ConfigMap |
| `k3s/manifests/dashy/service.yaml` | ClusterIP service on port 8080 |
| `k3s/manifests/dashy/ingress.yaml` | Tailscale ingress → `dashy.tailnet.ts.net` |
| `k3s/manifests/dashy/ingress-cloudflare.yaml` | Public Traefik ingress → `dashy.example.com` (Authentik ForwardAuth) |
| `k3s/manifests/dashy/namespace.yaml` | Namespace |
| `k3s/flux/apps/dashy.yaml` | Flux Kustomization |

---

## See Also

- [new-service.md](new-service.md) — Full guide for deploying a new service, including adding it to this dashboard
- [gitops-flux.md](gitops-flux.md) — How Flux sync and reconciliation work
- [Dashy documentation](https://dashy.to/docs/) — Official upstream config reference
