# Hosting Steam Game Servers (Parking & Resuming)

> How to run SteamCMD-based dedicated game servers (Project Zomboid, Valheim, etc.) on the k3s cluster, park them when nobody is playing to free CPU and RAM, and bring them back later with all world data intact.

---

## Overview

The cluster has a single worker (`k3s-agent-1`, about 8 cores / 25 GB RAM) and is already heavily requested. Game servers are the biggest consumers, so only run the ones people are actually playing.

The key idea: **compute and data are separate.**

| Piece | Kind | Costs CPU/RAM when parked? | Survives parking? |
|-------|------|----------------------------|-------------------|
| Deployment / Pod | Compute | Only while `replicas: 1` | Gone (that is the point) |
| PVC (`<game>-data`) | Data (Longhorn volume) | No, only disk space | **Yes** |
| Workshop/mod PVC | Re-downloadable cache | No, only disk space | **Yes** |
| Service / LoadBalancer IP | Networking | No | Yes (IP stays reserved) |
| Secret (Bitwarden) | Config | No | Yes |

**Parking** a server means scaling its Deployment to 0 replicas. The PVCs are never touched, so the world, configs and downloaded mods are all still there when you scale back up.

The reference implementation is Project Zomboid in `k3s/manifests/games/`.

---

## Parking and Resuming a Server

The cluster is managed by Flux (GitOps), which reverts manual changes. Pick the method that fits.

### Method A: GitOps (recommended, durable)

Edit the Deployment's replica count and push to `main`:

```yaml
# k3s/manifests/games/zomboid-deployment.yaml
spec:
  replicas: 0   # parked. Set back to 1 to resume
```

Flux applies it within ~10 minutes (or force it, see below). This survives Flux reconciles and node reboots, and the git history records what is parked.

### Method B: Quick, temporary (suspend Flux first)

Use this for a same-day stop/start without a commit:

```bash
# Stop Flux from reverting the change
flux suspend kustomization games -n flux-system

# Park
kubectl scale deployment/zomboid -n games --replicas=0

# Resume
kubectl scale deployment/zomboid -n games --replicas=1

# When finished, hand control back to Flux
flux resume kustomization games -n flux-system
```

> **Warning:** If you forget to resume Flux, later manifest changes to the `games` app will not apply. Note that suspending affects **all** apps in the `games` Kustomization.

### Force Flux to apply now

```bash
flux reconcile kustomization games -n flux-system --with-source
```

### Verify

```bash
kubectl get deploy,pods -n games     # READY 0/0 when parked
kubectl get pvc -n games             # PVCs must still be Bound
kubectl get nodes -o wide
kubectl top node                     # confirm resources were freed
```

After resuming, a large modded server can take a long time to start (Zomboid's startup probe allows 30 minutes). Watch progress:

```bash
kubectl logs -f deploy/zomboid -n games
```

---

## DO NOT: Ways to Accidentally Lose Data

The PVC is the only copy of your world. These actions delete it.

| Action | Result |
|--------|--------|
| Deleting `zomboid-pvc.yaml` from git while `prune: true` | Flux **prunes the PVC**; Longhorn deletes the volume (depends on the StorageClass reclaim policy, which defaults to `Delete`) |
| Removing the whole app from `k3s/flux/apps/kustomization.yaml` | Flux prunes everything it created, **including PVCs** |
| `kubectl delete pvc ...` or `kubectl delete ns games` | Data gone |
| Changing a PVC `storageClassName` or `accessModes` in git | Immutable field; the apply fails or forces recreation |

**Rule of thumb: park by setting `replicas: 0`, never by deleting manifests.**

> If you genuinely want to retire a game and keep its data, see [Long-term archive](#long-term-archive-remove-the-server-keep-the-data).

---

## Adding a New Steam Game Server

Follow the general flow in [Adding a New Service](new-service.md). Game servers are simpler: they use raw UDP/TCP through MetalLB, not HTTP ingress.

Put everything in `k3s/manifests/games/`. The `games` namespace and its Flux Kustomization (`k3s/flux/apps/games.yaml`) already exist, so no new Flux file is needed.

### 1. Find a container image

Look for an image that wraps SteamCMD and the dedicated server (for example `lloesche/valheim-server`, `cm2network/steamcmd`-based images, or the one used for Zomboid). Check the image docs for:

- Which ports it needs (and TCP vs UDP)
- **Which directories hold persistent data** (saves, config). This is the most important detail.
- Whether it installs/updates the game at startup (most do)

### 2. PVC for save data

Always use a dedicated PVC on Longhorn, named `<game>-data`:

```yaml
# k3s/manifests/games/valheim-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valheim-data
  namespace: games
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

Optionally add a second PVC for the downloaded game/workshop files. This is only a cache, but it saves a multi-GB redownload on every resume (Zomboid does this with `zomboid-workshop-data`).

### 3. Deployment

Required conventions:

- `replicas: 1` (or `0` when parked) and `strategy: Recreate`. The PVCs are `ReadWriteOnce`, so a rolling update would deadlock with two pods wanting the same volume.
- Mount the PVC at **exactly** the path the image writes saves to. Check the image's entrypoint if unsure. A wrong mount path means data lands in the ephemeral layer and is lost on restart.
- Always set `resources.requests` and `limits`, including `ephemeral-storage` (the `games` LimitRange only defaults it to 1Gi).
- Use a `startupProbe` with a generous window, because SteamCMD may download for minutes.
- Passwords come from a Secret, never inline.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valheim
  namespace: games
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: valheim
  template:
    metadata:
      labels:
        app: valheim
    spec:
      automountServiceAccountToken: false
      containers:
        - name: valheim
          image: <image>:<pinned-tag>   # pin a tag, not :latest
          ports:
            - containerPort: 2456
              protocol: UDP
              name: game
          env:
            - name: SERVER_PASS
              valueFrom:
                secretKeyRef:
                  name: valheim-credentials
                  key: SERVER_PASS
          volumeMounts:
            - name: data
              mountPath: /config        # <- path from the image docs
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
              ephemeral-storage: 4Gi
            limits:
              cpu: "4"
              memory: 4Gi
              ephemeral-storage: 8Gi
          startupProbe:
            tcpSocket:
              port: 2456                # use a TCP port if the game has one
            periodSeconds: 10
            failureThreshold: 90
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: valheim-data
```

> Many Steam games only expose UDP, so a `tcpSocket` probe won't work. In that case use an `exec` probe if the image has a suitable binary, or omit the liveness probe and keep only a generous startup window.

### 4. Service (MetalLB)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: valheim
  namespace: games
  annotations:
    # Disable k3s ServiceLB so MetalLB handles it
    svccontroller.k3s.cattle.io/nodeselectorsterm: "kubernetes.io/hostname in (none)"
spec:
  type: LoadBalancer
  selector:
    app: valheim
  ports:
    - port: 2456
      targetPort: 2456
      protocol: UDP
      name: game
```

MetalLB assigns an IP from `192.168.1.230-250`. Find it with `kubectl get svc -n games`. Keep admin ports (RCON) in a separate `ClusterIP` Service so they are not exposed.

The Service keeps its IP while the Deployment is scaled to 0 (nothing answers, but the IP stays reserved), so your router port-forward stays valid across park/resume.

### 5. Secrets

Use a `BitwardenSecret` like `zomboid-bw-secret.yaml`. Copy it and change the secret IDs and key names.

### 6. Capacity check before enabling

```bash
kubectl describe node k3s-agent-1 | grep -A8 "Allocated resources"
```

If requests are near 100%, the pod will sit `Pending`. Park another server first, or lower the new server's requests.

### 7. Port forward and test

Forward the game ports on the router to the MetalLB IP (see `k3s/manifests/minecraft/README.md` for the pattern), then connect from outside the LAN.

---

## Running Multiple Games with Limited Resources

Because the worker can only fit about one large server at a time, use "one active at a time" as the default:

1. Park the current game (`replicas: 0`).
2. Confirm resources are free (`kubectl top node`).
3. Resume the other game (`replicas: 1`).

You can keep every game's Deployment, Service and PVC in git at once. Parked ones cost only disk.

Suggested convention: in each Deployment, add a comment above `replicas` so state is obvious:

```yaml
spec:
  replicas: 0   # PARKED 2026-10-17, set to 1 to resume
```

---

## Backups of Game Data

A parked server is still protected by the existing backup tooling, but check these before relying on it:

- **Velero** (to AWS S3) backs up PVCs in the cluster. Confirm the `games` namespace is in the schedule's included namespaces and that volume data is captured (see the Velero manifests in `k3s/manifests/velero/` and [Phase 8](disaster-recovery/08-velero-restore.md)).
- **Longhorn snapshots** are good for quick rollbacks (for example before a game update or mod change). Take a snapshot in the Longhorn UI before risky changes.
- **One-off file export** (useful before an archive or migration):

```bash
# Start a temporary pod that mounts the PVC (server must be parked, since the volume is RWO)
kubectl run pvc-copy -n games --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"pvc-copy","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"zomboid-data"}}]}}'

kubectl cp games/pvc-copy:/data ./zomboid-backup
kubectl delete pod pvc-copy -n games
```

---

## Long-term Archive (Remove the Server, Keep the Data)

If you want to remove a game's Deployment and Service from git entirely but keep the save:

1. Park the server and take a Longhorn snapshot and/or export files (above).
2. Keep the PVC manifest in the `games` directory and delete only the Deployment, Service and secret manifests. Flux prunes only what is no longer in git, so the PVC stays.
3. Optionally, set the PV reclaim policy to `Retain` so the data survives even an accidental PVC delete:

```bash
PV=$(kubectl get pvc zomboid-data -n games -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

To resume later, restore the Deployment and Service manifests from git history. The PVC is still there and the server picks up where it left off.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pod `Pending` after resume | Not enough CPU/RAM on the worker | Park another server or lower requests |
| Pod stuck `ContainerCreating`, volume attach error | Old pod still holds the RWO volume, or Longhorn is slow to detach | Wait a few minutes; make sure the strategy is `Recreate`; check the Longhorn UI |
| Server starts with a fresh world | Wrong mount path, so saves are going somewhere else | Compare `mountPath` with the image docs; inspect the old data with a temporary pod |
| Resume re-downloads gigabytes | No persistent cache for game/workshop files | Add a second PVC for that directory |
| `kubectl scale` gets undone | Flux reverted it | Use Method A, or suspend Flux |
| Server restarts repeatedly right after start | `startupProbe` window too short for SteamCMD | Increase `failureThreshold` |
| Players can't connect | Port-forward points to the wrong IP or protocol | Check `kubectl get svc -n games` and the UDP/TCP settings |

---

## Quick Reference

```bash
# Park / resume (with Flux suspended)
flux suspend kustomization games -n flux-system
kubectl scale deploy/<game> -n games --replicas=0
kubectl scale deploy/<game> -n games --replicas=1
flux resume kustomization games -n flux-system

# Status
kubectl get deploy,pods,pvc,svc -n games
kubectl logs -f deploy/<game> -n games
kubectl describe node k3s-agent-1 | grep -A8 "Allocated resources"
```
