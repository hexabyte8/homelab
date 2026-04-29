# Fail2ban

This document covers the fail2ban deployment in this homelab: architecture, configuration management, day-to-day operations, and troubleshooting.

---

## Overview

fail2ban runs as a **DaemonSet** in the `fail2ban` namespace, placing one pod on every node in the cluster. It monitors host log files and uses `nftables` to ban IPs that trigger too many failed authentication attempts.

| Item | Value |
|---|---|
| Namespace | `fail2ban` |
| Workload | DaemonSet |
| Image | `crazymax/fail2ban:1.0.2` (Alpine-based) |
| Nodes covered | `k3s-server`, `k3s-agent-1`, `k3s-agent-2` |
| Ban database | `/var/lib/fail2ban` (hostPath, per-node) |
| Flux Kustomization | `fail2ban` (namespace `flux-system`) |

---

## Architecture

### Why a DaemonSet?

Each node independently reads its own host logs and manages its own `nftables` rules. A DaemonSet ensures every node is protected — a single Deployment pod would only protect the node it lands on.

### Networking and privileges

The pod runs with:
- `hostNetwork: true` — reads network state from the host network namespace
- `hostPID: true` — allows access to host process information
- `privileged: true` — required to manipulate host `nftables` rules

Tolerations allow the pod to schedule on control-plane nodes (which carry a `node-role.kubernetes.io/control-plane` taint by default).

### Configuration management

All fail2ban configuration lives in a **ConfigMap** (`fail2ban-config`) in git at `k3s/manifests/fail2ban/configmap.yaml`. Flux syncs changes to this ConfigMap within ~10 minutes of a push to `main`.

> **Important:** syncing the ConfigMap does **not** restart the DaemonSet pods. See [Updating configuration](#updating-configuration) below.

---

## Volumes

| Mount path (container) | Source | Mode |
|---|---|---|
| `/var/log/host` | Host `/var/log` | Read-only |
| `/data/jail.d/jail.local` | ConfigMap key `jail.local` | `subPath` mount |
| `/data/filter.d/k3s-apiserver.conf` | ConfigMap key `k3s-apiserver.conf` | `subPath` mount |
| `/run/xtables.lock` | Host `/run/xtables.lock` | Read-write |
| `/var/lib/fail2ban` | Host `/var/lib/fail2ban` | Read-write (ban database) |

The `subPath` mounts are required because Kubernetes ConfigMap keys cannot contain `/` — the filename is used as the key and placed at the correct path inside the container.

---

## Jails

### Default settings (applied to all jails unless overridden)

| Setting | Value | Notes |
|---|---|---|
| `ignoreip` | `127.0.0.1/8 ::1 100.64.0.0/10` | Loopback + Tailscale CGNAT — tailnet peers are never banned |
| `banaction` | `nftables-multiport` | Uses nftables instead of iptables |
| `findtime` | `10m` | Window for counting failures |
| `bantime` | `1h` | Default ban duration |
| `maxretry` | `5` | Default failure threshold |

### `sshd`

| Setting | Value |
|---|---|
| Log path | `/var/log/host/auth.log` |
| `maxretry` | `3` |
| `bantime` | `24h` |

Monitors SSH authentication failures. The tighter limits (3 retries, 24-hour ban) reflect the higher risk of brute-force SSH attacks.

### `k3s-apiserver`

| Setting | Value |
|---|---|
| Log path | `/var/log/host/syslog` |
| `maxretry` | `10` |
| `bantime` | `1h` |

Monitors the k3s API server for repeated unauthorised or malformed requests. k3s forwards its logs to rsyslog, which writes them to `/var/log/syslog` on the host.

---

## Updating configuration

1. Edit `k3s/manifests/fail2ban/configmap.yaml` in git.
2. Push to `main` — Flux syncs the ConfigMap within ~10 minutes.
3. **Restart the DaemonSet pods** to pick up the new config:

   ```bash
   kubectl rollout restart daemonset/fail2ban -n fail2ban
   ```

   Alternatively, delete all pods and let the DaemonSet recreate them:

   ```bash
   kubectl delete pods -n fail2ban --all
   ```

DaemonSet pods do not restart automatically when a mounted ConfigMap changes.

---

## Managing bans (GitHub Actions)

> **Do not** manage bans via SSH or `kubectl exec` directly. Use the GitHub Actions workflow — it handles all 3 nodes consistently.

### Running the workflow

1. Go to **GitHub Actions → "Ansible - Manage Fail2ban" → Run workflow**.
2. Fill in the inputs:

| Input | Description | Default |
|---|---|---|
| `action` | `list_bans`, `ban`, or `unban` | — |
| `jail` | Jail name to target | `sshd` |
| `ip` | IP address (required for `ban` / `unban`) | — |

### What happens under the hood

The Ansible playbook runs on `k3s-server` and uses `kubectl exec` to reach the fail2ban pod on each node:

- **`list_bans`**: queries all 3 nodes and aggregates results.
- **`ban` / `unban`**: applies the action to all 3 nodes simultaneously so ban state stays consistent across the cluster.

---

## Troubleshooting

### Check pod status across all nodes

```bash
kubectl get pods -n fail2ban -o wide
```

### View fail2ban logs for a specific pod

```bash
# Replace <pod-name> with the actual pod name from the command above
kubectl logs -n fail2ban <pod-name> --tail=100 -f
```

### Check current bans on a node

```bash
kubectl exec -n fail2ban <pod-name> -- fail2ban-client status sshd
kubectl exec -n fail2ban <pod-name> -- fail2ban-client status k3s-apiserver
```

### ConfigMap key validation error (invalid key containing `/`)

**Symptom:** Flux reconciliation fails with:

```
ConfigMap "fail2ban-config" is invalid: data[filter.d/k3s-apiserver.conf]: Invalid value
```

**Cause:** Kubernetes ConfigMap keys must match `[-._a-zA-Z0-9]+` — slashes are not permitted.

**Fix:** Use just the filename as the ConfigMap key (e.g. `k3s-apiserver.conf`) and mount it with a `subPath` volumeMount to place it at the correct path inside the container:

```yaml
volumeMounts:
  - name: config
    mountPath: /data/filter.d/k3s-apiserver.conf
    subPath: k3s-apiserver.conf
```

### `IsADirectoryError` on journal path

**Symptom:** fail2ban crashes with:

```
IsADirectoryError(21, 'Is a directory')
```

**Cause:** `logpath` was set to `/var/log/journal`, which is a directory of binary files. The pyinotify backend cannot tail a directory.

**Fix:** Use `logpath = /var/log/host/syslog` instead. k3s forwards its logs to rsyslog, so they appear in the standard syslog file.

### `No module named 'systemd'` / `backend = systemd` fails

**Cause:** `crazymax/fail2ban` is Alpine-based and does not ship `python3-systemd`.

**Fix:** Use `backend = auto` (resolves to pyinotify) with a file-based `logpath`. Do not use `backend = systemd` with this image.

### ConfigMap change not picked up after Flux reconcile

**Symptom:** Pods still show the old configuration after Flux reports the kustomization as **Ready**.

**Cause:** DaemonSet pods are not automatically restarted when a mounted ConfigMap changes.

**Fix:**

```bash
kubectl rollout restart daemonset/fail2ban -n fail2ban
```

Or delete all pods to force immediate recreation:

```bash
kubectl delete pods -n fail2ban --all
```
