# Calibre-Web

[Calibre-Web Automated](https://github.com/crocodilestick/Calibre-Web-Automated) (CWA) is a web-based ebook library manager built on top of [Calibre-Web](https://github.com/janeczku/calibre-web). In addition to the standard Calibre-Web reading and management interface, CWA adds an automatic book ingestion pipeline: drop an ebook file into the ingest directory and it is automatically imported, converted (if needed), and added to the Calibre library without any manual intervention.

## Access

| Path | URL |
|------|-----|
| Private (tailnet) | `https://calibre-web.tailnet.ts.net` |
| Public (Authentik SSO required) | `https://calibre.example.com` |

## Architecture

```
Internet → Cloudflare Edge → cloudflared → Traefik
                                           → cloudflare-https-scheme middleware
                                           → Authentik ForwardAuth middleware
                                           → Calibre-Web (port 8083)

Tailnet → Tailscale Ingress proxy → Calibre-Web (port 8083)
```

| Component | Image | Purpose |
|-----------|-------|---------|
| Calibre-Web Automated | `crocodilestick/calibre-web-automated:latest` | Ebook library UI + auto-ingest |

Calibre-Web runs in the `jellyfin` namespace and shares the `jellyfin-media` Longhorn volume. This co-location is required because `jellyfin-media` is `ReadWriteOnce` — only one node can mount it — so Calibre-Web must be scheduled on the same Kubernetes node as Jellyfin. A `podAffinity` rule enforces this.

## Storage

| PVC | Size | Storage class | Mount path | Contents |
|-----|------|---------------|------------|----------|
| `calibre-web-config` | 5Gi | `longhorn` | `/config` | CWA database, app config, metadata cache |
| `jellyfin-media` (shared) | 350Gi | `longhorn-media` | `/calibre-library` (subPath: `books`) | Calibre library — metadata and ebook files |
| `jellyfin-media` (shared) | — | — | `/cwa-book-ingest` (subPath: `cwa-ingest`) | Drop zone for automatic book ingestion |

The Calibre library lives inside the shared media volume under `books/`, making the ebook files visible to FileBrowser and — if a Jellyfin ebook plugin is in use — to Jellyfin as well. New books placed in `cwa-ingest/` are automatically imported by CWA.

## Environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `PUID` | `1000` | Run as UID 1000 for consistent file ownership on the shared PVC |
| `PGID` | `1000` | Run as GID 1000 |
| `TZ` | `UTC` | Timezone for the container |

## Cloudflare public access and Authentik

The Cloudflare Tunnel ingress applies a two-middleware chain:

```
traefik.ingress.kubernetes.io/router.middlewares: >-
  kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd
```

- **`cloudflare-https-scheme`** (must come first): rewrites `X-Forwarded-Proto` from `http` to `https`. Because `cloudflared` connects to Traefik over plain HTTP, the proto header would otherwise read `http`, causing Authentik to build `http://` OIDC callback URLs and fail with a 400 error.
- **`authentik-authentik-forward-auth`**: gates access behind Authentik SSO. Unauthenticated requests are redirected to `https://authentik.tailnet.ts.net` for login.

After deploying the Cloudflare ingress, the Authentik configuration must be completed in the web UI. See [authentik.md](authentik.md) for the full procedure:

1. Create a **Proxy Provider** (Forward auth, single application) with External Host `https://calibre.example.com`.
2. Create an **Application** linked to the provider.
3. Assign the application to the **Embedded Outpost**.

## Initial setup

### First login

The first time Calibre-Web starts it initialises an empty SQLite database in `/config`. Navigate to `https://calibre-web.tailnet.ts.net` and log in with the default credentials:

- **Username**: `admin`
- **Password**: `admin123`

Change the admin password immediately under **Admin → Edit User**.

### Calibre library path

After first login, CWA will prompt for the Calibre library location. Set it to:

```
/calibre-library
```

This points to the `books/` sub-path of `jellyfin-media`. If the directory is empty, CWA creates a fresh Calibre database (`metadata.db`) there. If you are restoring a pre-existing library, ensure the `metadata.db` and book files are already present in `jellyfin-media/books/` before starting the pod.

### Automatic book ingestion

Drop ebook files (`.epub`, `.mobi`, `.pdf`, etc.) into the `cwa-ingest/` directory inside `jellyfin-media` (accessible via FileBrowser at `/srv/cwa-ingest/`). CWA watches this directory and automatically:

1. Detects the new file.
2. Converts it to EPUB if necessary.
3. Imports it into the Calibre library with extracted metadata.
4. Removes the original from the ingest directory.

## Upgrading

Calibre-Web Automated uses `imagePullPolicy: Always` with the `latest` tag. To pick up a new release:

```bash
kubectl rollout restart deployment/calibre-web -n jellyfin
```

Check the [CWA releases page](https://github.com/crocodilestick/Calibre-Web-Automated/releases) for breaking changes before restarting, particularly any that affect the database schema or library path conventions.

## Troubleshooting

### Authentik auth loop (400 error on login)

Ensure `kube-system-cloudflare-https-scheme@kubernetescrd` is the **first** middleware in the chain on the Cloudflare ingress. Swapping the order causes Authentik to receive `X-Forwarded-Proto: http` and generate an invalid OIDC callback URL. See [cloudflare-tunnels.md](cloudflare-tunnels.md) for background.

### Pod pending — unable to schedule

Because `jellyfin-media` is `ReadWriteOnce`, the Calibre-Web pod must be scheduled on the same node as Jellyfin. If the Jellyfin pod is not running, Calibre-Web will remain pending. Check Jellyfin first:

```bash
kubectl get pods -n jellyfin -l app=jellyfin
kubectl get pods -n jellyfin -l app=calibre-web
```

### Ingest directory not being watched

Confirm the `cwa-ingest` subPath mount is present and writable:

```bash
kubectl exec -n jellyfin deployment/calibre-web -- ls -la /cwa-book-ingest
```

If the directory is missing or shows a permissions error, check that the `jellyfin-media` PVC is healthy and that the `subPath: cwa-ingest` directory exists within it (FileBrowser can create it if needed).

### Library not found on startup

If CWA reports that the library cannot be found at startup, verify that `metadata.db` exists in the correct location:

```bash
kubectl exec -n jellyfin deployment/calibre-web -- ls -la /calibre-library/
```

If the directory is empty, re-enter `/calibre-library` as the library path in the CWA setup wizard, which will initialise a new empty library.
