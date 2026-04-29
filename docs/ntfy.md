# Ntfy

[Ntfy](https://github.com/binwiederhier/ntfy) is a self-hosted push notification service. It uses a simple HTTP pub/sub model — any service or script can publish a notification to a topic with a single `curl` call, and subscribers (phone apps, browser, other services) receive it instantly.

## Access

| Path | URL |
|------|-----|
| Private (tailnet only) | `https://ntfy.tailnet.ts.net` |

The ntfy server is exposed only on the tailnet. This is intentional: topic names act as a shared secret, so keeping the server off the public internet prevents topic enumeration and unwanted subscriptions.

## Architecture

```
Publisher (curl / service) → ntfy ClusterIP (port 80)
                                    ↓
                             Ntfy server (pub/sub broker)
                                    ↓
Subscriber ← Tailscale Ingress ← ntfy server
(app / browser)
```

| Component | Image | Purpose |
|-----------|-------|---------|
| Ntfy | `binwiederhier/ntfy:v2.11.0` | Push notification broker |

## Storage

| PVC | Size | Mount | Contents |
|-----|------|-------|----------|
| `ntfy-data` | 1Gi | `/var/cache/ntfy` | Message cache database (`cache.db`) |

The message cache (`cache.db`) persists notifications so subscribers that were offline when a message was published can still retrieve it on reconnect. Cache size is managed automatically by ntfy.

## Configuration

Key environment variables set on the deployment:

| Variable | Value | Description |
|----------|-------|-------------|
| `NTFY_CACHE_FILE` | `/var/cache/ntfy/cache.db` | Path to the SQLite message cache |
| `NTFY_BASE_URL` | `https://ntfy.tailnet.ts.net` | Canonical public URL (used in notification click-through links) |
| `NTFY_BEHIND_PROXY` | `true` | Tells ntfy to trust `X-Forwarded-For` headers from the Tailscale proxy |

No authentication is configured. Any tailnet member (or cluster workload) can publish and subscribe to any topic.

## Subscribing to topics

### Ntfy mobile app (Android / iOS)

1. Install the [ntfy app](https://ntfy.sh/#subscribe).
2. Add a new subscription → enter server URL: `https://ntfy.tailnet.ts.net`
3. Enter a topic name (e.g. `homelab-alerts`).
4. The app will show a push notification for every message published to that topic.

### Browser

Open `https://ntfy.tailnet.ts.net/<topic>` in a browser and click **Subscribe** to receive desktop notifications.

### CLI

```bash
# Subscribe and stream messages to stdout
curl -s https://ntfy.tailnet.ts.net/homelab-alerts/json
```

## Publishing notifications

### From outside the cluster (tailnet)

```bash
curl -d "Backup completed successfully" \
  https://ntfy.tailnet.ts.net/homelab-alerts
```

With a title and priority:

```bash
curl \
  -H "Title: Deployment failed" \
  -H "Priority: urgent" \
  -H "Tags: warning" \
  -d "Flux reconcile error on linkwarden" \
  https://ntfy.tailnet.ts.net/homelab-alerts
```

### From inside the cluster

Other cluster workloads (CronJobs, init containers, alerting sidecars) can reach ntfy directly via ClusterIP without leaving the cluster:

```bash
curl -d "Database backup finished" \
  http://ntfy.ntfy.svc.cluster.local/homelab-alerts
```

This avoids Tailscale round-trips and works even if the tailnet is unreachable.

### From a Kubernetes CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: example-notifier
  namespace: mynamespace
spec:
  schedule: "0 3 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: notify
              image: curlimages/curl:latest
              args:
                - curl
                - -d
                - "Nightly task completed"
                - http://ntfy.ntfy.svc.cluster.local/homelab-alerts
```

## Topic naming

Topics are created on first publish — no setup required. Choose descriptive names to keep things organised:

| Topic | Suggested use |
|-------|--------------|
| `homelab-alerts` | General cluster alerts and events |
| `backup-status` | Backup job results |
| `flux-events` | Flux reconciliation success / failure |
| `cron-results` | CronJob completions |

## Upgrading

Ntfy is pinned to `v2.11.0`. To upgrade, update the image tag in `k3s/manifests/ntfy/deployment.yaml` and commit. Check the [ntfy changelog](https://github.com/binwiederhier/ntfy/releases) for breaking changes — particularly any cache database migrations.

## Troubleshooting

### Notifications not delivered to app

1. Verify the pod is running and healthy:
   ```bash
   kubectl get pods -n ntfy
   kubectl logs deployment/ntfy -n ntfy
   ```
2. Check the health endpoint:
   ```bash
   curl https://ntfy.tailnet.ts.net/v1/health
   # Expected: {"healthy":true}
   ```
3. Confirm the mobile app server URL matches exactly (`https://ntfy.tailnet.ts.net`).

### Messages not persisted across restarts

Confirm the PVC is bound and the cache file is writable:

```bash
kubectl get pvc ntfy-data -n ntfy
kubectl exec deployment/ntfy -n ntfy -- ls -lh /var/cache/ntfy/
```
