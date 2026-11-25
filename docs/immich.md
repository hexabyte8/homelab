# Immich

Immich is reconciled by Flux in the `immich` namespace. Its only external
ingress is the Tailscale HTTPS proxy at
`https://immich.daggertooth-scala.ts.net`; tailnet ACLs still determine who can
reach it. Sign in through the web UI or use that URL in the mobile app.
Create the administrator account promptly after deployment: the first visitor
to the setup page can create it.

The server and machine-learning images are pinned to the same Immich release.
Valkey is ephemeral; the photo library is a 50Gi Longhorn `longhorn-media` PVC,
and a dedicated CloudNativePG PostgreSQL 14 instance has a 10Gi Longhorn
volume. CNPG generates the `immich-db-app` password; no Bitwarden bootstrap is
needed. Immich's database role is a superuser on this dedicated database
cluster, as required for its extension management and automatic database dumps.
The machine-learning model cache is ephemeral and downloads again after a pod
restart. Check available Longhorn capacity before deploying or expanding the
library PVC.

## Backups and upgrades

The library storage class has one replica and is **not a backup**. Velero is
configured to copy mounted volumes to S3 daily at 04:00 UTC, after Immich's
default 02:00 database dump. Immich writes its dumps to `/data/backups` on
the library volume. Once Flux has created the `velero` namespace, run the
`k3s - Patch Cluster Secrets` workflow with `target: bw-auth-token` if that
namespace does not already have the token. Confirm that the credentials
sync, the backup storage location is available, and a completed Velero backup
includes the Immich library and a recent, complete database dump.

Do not treat a filesystem copy of a running PostgreSQL data directory as a
consistent database backup. Test restoring both the photos and the database
dump, and maintain another independent copy as described in the
[Immich backup guidance](https://docs.immich.app/administration/backup-and-restore/).

Flux pruning is disabled for the namespace, database cluster and library PVC
to reduce accidental deletion; deleting the namespace explicitly still deletes
its resources. The media storage class retains its PV when the PVC is deleted.
Before updating Immich, back up both photos and database, read upstream release
notes, and upgrade the server and machine-learning images together. Check
VectorChord and PostgreSQL compatibility before changing the database image.
