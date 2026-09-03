# Phase 8: Velero Cluster Restore

> **Time estimate:** ~20-40 minutes
>
> **What this does:** Restores cluster workloads, PVC-backed data, and namespace-scoped resources from the Velero S3 backups after the base cluster is already rebuilt.

---

## When to Use This in the Recovery Sequence

> **Run this phase after [Phase 6: Secrets Restore](./06-secrets-restore.md) and before
> [Phase 7: Validation](./07-validation.md).** Velero itself is deployed by Flux (Phase 5)
> and needs the `velero-s3-credentials` Secret synced by the sm-operator (Phase 6) before
> it can talk to S3 — restoring any earlier is not possible. Running the final validation
> checklist (Phase 7) after this phase means you validate the cluster *with your real data
> back in it*, not an empty freshly-bootstrapped one.

Use Velero to restore the cluster's workload state and volume data from S3 instead of
starting every application from a blank slate. This phase is what actually brings back
your application data (Longhorn PVC contents, Secrets, ConfigMaps) — Flux alone only
recreates the *desired manifests*, not the runtime state or data that lived inside them.

This is especially useful when you need to recover:

- application PVC data
- namespace Secrets and ConfigMaps
- Deployments, Services, Ingresses, and other workload resources
- namespace-level state that Git alone does not preserve

In other words: **Flux recreates the desired manifests, but Velero restores the runtime state and volume contents.**

---

## Prerequisites

Before starting this phase, confirm all of the following:

- Phases **1 through 6** are complete (Proxmox, VMs, k3s, Flux bootstrap, secrets seeded)
- Velero is deployed and running from `k3s/manifests/velero/`
- The S3 backup bucket exists and is accessible
- The `velero-s3-credentials` Secret is present in the cluster after `bw-auth-token` has been seeded and the sm-operator has synced BitwardenSecrets

Recommended quick checks:

```bash
kubectl get pods -n velero
kubectl get secret velero-s3-credentials -n velero
velero backup get
```

---

## How Backup Storage Is Provisioned

The `opentofu/aws` stack provisions the complete Velero storage path:

- a dedicated `daggertooth-cluster-backups` S3 bucket
- S3 versioning, AES-256 server-side encryption, and public-access blocking
- a dedicated `homelab-velero` IAM user restricted to that bucket
- an IAM access key exposed only as a sensitive OpenTofu output

After an AWS stack apply, the reusable workflow writes the generated AWS
credentials file to the existing Velero BWS entry. The sm-operator then syncs
that value into the `velero-s3-credentials` Kubernetes Secret. No manual bucket
or IAM credential setup is required.

Velero runs the `velero-daily-full` schedule at **02:00 UTC**, retains backups for 30 days, and uses
its node agent to copy Longhorn PVC contents into S3. Longhorn volumes use
filesystem backup rather than AWS EBS snapshots.

---

## Method A — GitHub Actions (Recommended)

The easiest and safest recovery path is the dedicated GitHub Actions workflow:

- **Actions → k3s - Velero Cluster Restore → Run workflow**

### Recommended input values

- **target_host:** `k3s-server`
- **backup_name:** leave empty to auto-select the latest completed `velero-daily-full-*` backup
- **restore_namespaces:** leave empty to restore everything
- **wait_timeout:** `30m` is a good default
- **dry_run:** set to **true first**

### Recommended sequence

1. Run the workflow with **dry_run = true**.
2. Review the listed backup and proposed restore.
3. Re-run the workflow with **dry_run = false**.
4. Wait for the restore to complete.
5. Review the post-restore health output.

### Expected runtime

- Small cluster / light data: ~20 minutes
- Larger PVC restores: up to ~40 minutes or more

---

## Method B — Manual velero CLI

If GitHub Actions is unavailable, you can restore directly with the Velero CLI.

### 1. Install the Velero CLI

Follow the upstream install instructions or download the matching Linux release from GitHub.

### 2. List backups

```bash
velero backup get
```

### 3. Create a restore

```bash
velero restore create --from-backup <name>
```

To limit the scope:

```bash
velero restore create \
  --from-backup <name> \
  --include-namespaces authentik,forgejo,jellyfin
```

### 4. Wait for completion

```bash
velero restore wait <restore-name>
```

### 5. Inspect details

```bash
velero restore describe <restore-name> --details
```

---

## What Gets Restored vs What Does Not

### Restored

Velero restores the namespace-scoped workload state, including:

- Deployments
- Services
- ConfigMaps
- Secrets
- PVC-backed application data (via node-agent / restic or kopia)
- other namespace resources included in the backup

### Not Restored by Default

In this homelab recovery model, do **not** rely on Velero for:

- cluster nodes
- most cluster-scoped infrastructure resources
- storage-provider-specific objects outside the restore scope
- the `kube-system` namespace (typically excluded by Velero best practices)

Flux and OpenTofu are still responsible for reconciling the cluster-scoped infrastructure from git.

---

## Post-Restore Checklist

After the restore completes, work through this list:

- [ ] Run `k3s-patch-secrets` with `target: bw-auth-token` to re-seed the sm-operator token
- [ ] Wait about **5 minutes** for the sm-operator to sync all `BitwardenSecret` resources
- [ ] Confirm `kubectl get bitwardensecret -A` shows healthy status
- [ ] Run **OpenTofu Apply** for `authentik` if user accounts, applications, or flows need to be reprovisioned
- [ ] Verify the Velero backup storage location is healthy
- [ ] Check cluster health with `kubectl get nodes`
- [ ] Check for failed pods with `kubectl get pods -A | grep -v Running | grep -v Completed`
- [ ] Spot-check critical apps such as Authentik, Forgejo, and Longhorn

---

## Verifying Backup Health Before Disaster Recovery

Do not wait for a disaster to discover the backups are broken.

### Check scheduled backups

```bash
velero schedule get
velero backup get
```

You want to see recent successful `velero-daily-full-*` backups.

### Check the backup storage location

```bash
velero backup-location get
```

The default location should report as available / healthy.

### Spot-check restore readiness

Run a periodic dry-run restore from the workflow or CLI to confirm the cluster can still enumerate and use the backup set.

---

## Summary

Use Velero after the base platform is rebuilt but before spending time manually recovering app state. Flux restores what the cluster **should** look like; Velero restores the data and namespace resources needed to get back to the last good operational state quickly.

---

## Proceed to Phase 7: Validation

Once the restore is confirmed healthy, continue to [Phase 7: Validation](./07-validation.md) to run the final end-to-end health checks against the fully restored cluster.
