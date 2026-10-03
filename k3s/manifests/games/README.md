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
- Sized to fit actual cluster capacity: CPU request 2 / limit 4
  (Burstable), memory request = limit = 8Gi (JVM `MIN_MEMORY=4096m` /
  `MAX_MEMORY=6144m`). Each node only has ~4 allocatable CPU and
  agents only ~11.7Gi allocatable memory total, so don't raise these
  without checking free capacity first (`kubectl describe nodes`).

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
