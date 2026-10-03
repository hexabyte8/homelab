# games namespace

Namespace for Minecraft/Steam-based dedicated game servers. Currently hosts
a single Project Zomboid dedicated server.

## Project Zomboid

- Image: `danixu86/project-zomboid-dedicated-server:42.21-release-2`
  (pinned to a stable release tag rather than `latest`).
- Data PVC (`zomboid-data`, `longhorn` SC, standard replication since save
  data isn't re-downloadable) is mounted at `/home/steam/Zomboid` — the
  image's hardcoded `HOMEDIR`. Its entrypoint only pre-creates directories
  under `HOMEDIR` regardless of any `CACHEDIR` override, so mounting
  anywhere else (e.g. a custom `/data` path) causes a
  `FileNotFoundException` crash on first boot.
- `startupProbe`/`livenessProbe` use `tcpSocket` against the RCON port
  (27015) rather than `exec` — the image has no `pgrep`/`ps`.
- Build 42+ only needs two UDP ports (`16261`, `16262`) plus the two Steam
  UDP ports (`8766`, `8767`); the older per-player TCP client-slot port
  range is obsolete and not exposed.
- `SERVERNAME` is `homelab`; `ADMINPASSWORD`/`RCONPASSWORD` come from a
  Bitwarden-backed secret (`zomboid-bw-secret.yaml`) — see that file's
  comments for the single-key-per-`bwSecretId` sm-operator quirk.
- Sized at CPU request 4 / limit 6 (Burstable), memory request = limit =
  16Gi (JVM `MIN_MEMORY=8192m` / `MAX_MEMORY=14336m`), per the requirement
  to give the server 16GB of RAM. The cluster was consolidated to a
  single worker (`k3s-agent-1`, resized to 8 cores / 25600Mi) specifically
  to make room for this — the node now sits at ~90% CPU / ~97% memory
  requested, so there's effectively no headroom left for other workloads.
  Check free capacity first (`kubectl describe node k3s-agent-1`) before
  raising these any further.

### Migrating an existing save (.zip) from another server

PZ data lives entirely under `/home/steam/Zomboid` (the PVC's mount root),
with saves in `Saves/Multiplayer/<servername>/` and config in
`Server/<servername>.ini`, `<servername>_SandboxVars.lua`, etc. Our
server's `SERVERNAME` is `homelab`, so either rename the old save's
files/folder to `homelab`, or change the `SERVERNAME` env var to match the
old server's name instead.

```bash
# 1. Stop the server so nothing writes while you copy
kubectl -n games scale deployment zomboid --replicas=0

# 2. Spin up a helper pod on the same PVC
kubectl -n games run zomboid-migrate --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"migrate","image":"busybox","command":["sleep","3600"],
  "volumeMounts":[{"name":"data","mountPath":"/data"}]}],
  "volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"zomboid-data"}}]}}'

# 3. Copy the zip in, then unzip (busybox has an unzip applet)
kubectl -n games cp ./old-server-backup.zip zomboid-migrate:/tmp/backup.zip
kubectl -n games exec zomboid-migrate -- sh -c "cd /data && unzip -o /tmp/backup.zip"
# If the zip contains a top-level "Zomboid/" folder, merge its contents up
# one level instead, since /data IS already ~/Zomboid.

# 4. Clean up and restart
kubectl -n games delete pod zomboid-migrate
kubectl -n games scale deployment zomboid --replicas=1
kubectl -n games logs -f deploy/zomboid
```

For a multi-GB save, `kubectl cp` can be flaky — if it fails/times out,
use a `tar`-pipe copy instead (stream via `kubectl exec ... tar | kubectl
exec -i ... tar`, re-running until source/dest file counts and sizes
match — the same technique used for the Jellyfin→media migration).

**Gotcha**: if the migrated INI already has `Mods=`/`WorkshopItems=` set,
the entrypoint will **blank them out on boot** unless you set
`SELF_MANAGED_MODS=true` (see below) or set matching `MOD_IDS`/
`WORKSHOP_IDS` env vars.

### Adding mods

Entirely through Deployment env vars (semicolon-separated Workshop/Mod
IDs, matching PZ's own INI format) — no manual file editing needed:

```yaml
- name: WORKSHOP_IDS
  value: "2434187621;2615577844"
- name: MOD_IDS
  value: "modid1;modid2"
```

The server downloads Workshop items itself via Steam on boot and
auto-detects any shipped maps. Edit `zomboid-deployment.yaml`, commit,
open a PR (branch protection requires it), merge, and let Flux reconcile
— the pod restarts with mods active.

If you migrated a save that already has mods configured in its INI and
want to manage that file directly instead of via env vars, add
`SELF_MANAGED_MODS: "true"` so the entrypoint leaves `Mods`/
`WorkshopItems` untouched.

### Automatic mod updates (`pz-mod-updater`)

`pz-mod-updater` (`pz-mod-updater-cronjob.yaml`, `pz-mod-updater-rbac.yaml`)
is a small CronJob, running every 15 minutes, that:

1. Reads the live `WORKSHOP_IDS` off the `zomboid` Deployment.
2. Checks Steam's Workshop API for each mod's current version.
3. If any mod updated, checks RCON player count — defers the restart if
   anyone's online, otherwise patches `zomboid` with a rollout-restart
   annotation (equivalent to `kubectl rollout restart deployment/zomboid`)
   so the image re-downloads the updated mod(s) on the next boot.

It reuses the same `zomboid-credentials` Bitwarden-synced secret for RCON
auth (`ADMINPASSWORD` doubles as `RCONPASSWORD`, see
`zomboid-bw-secret.yaml`'s comment) and persists last-seen mod versions in
a `pz-mod-state` ConfigMap it creates on first run.

Source: [hexabyte8/pz-mod-updater](https://github.com/hexabyte8/pz-mod-updater).
Image is published to `ghcr.io/hexabyte8/pz-mod-updater` on every push to
`main`. To see what it decided on its last run:

```bash
kubectl -n games logs job/$(kubectl -n games get jobs -l job-name --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
```

### Connecting from outside the LAN

The `zomboid` Service is `type: LoadBalancer`, fronted by MetalLB —
`kubectl -n games get svc zomboid` shows the assigned LAN IP. To let
Internet clients connect, forward **UDP 16261 and 16262** on the router to
that MetalLB IP. See the repo root `opentofu/cloudflare/dns.tf` for the
public DNS/SRV record pointing at the home router's public IP.
