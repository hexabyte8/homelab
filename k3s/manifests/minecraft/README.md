# minecraft

Public Minecraft server using [`itzg/minecraft-server`](https://docker-minecraft-server.readthedocs.io/)
with CurseForge modpack support (`TYPE=AUTO_CURSEFORGE`).

## Modding via GitOps

Edit `configmap.yaml` and merge: `CF_SLUG` selects the modpack,
`CF_FILENAME_MATCHER` pins a version, `CF_EXCLUDE_MODS` /
`CF_FORCE_INCLUDE_MODS` tweak mods, `MODS` adds extra CurseForge mods.
Reloader restarts the pod and the image re-resolves the pack on boot.
World/mod data persists on the `minecraft-data` PVC.

## Setup

1. Get a CurseForge API key (https://console.curseforge.com/).
2. `minecraft-secrets` (`CF_API_KEY`, `RCON_PASSWORD`) is synced from Bitwarden by `bw-secret.yaml`.
3. Forward TCP 25565 on the router to the Service's MetalLB IP
   (`kubectl -n minecraft get svc minecraft`) and point a DNS record at it.
4. Set `WHITELIST`/`OPS` in the ConfigMap; `MEMORY` is 16G (pod requests 16Gi, limit 20Gi).
