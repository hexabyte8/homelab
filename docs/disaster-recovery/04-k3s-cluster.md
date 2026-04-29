# Phase 4: k3s Cluster Setup

> **Time estimate:** ~20 minutes
>
> **Prerequisites:** All 4 VMs are online on Tailscale (verified in Phase 3)

---

## What is k3s?

k3s is a lightweight version of Kubernetes (the container orchestration system).
Kubernetes manages running multiple containers (applications) across multiple machines,
restarting them if they crash, balancing load, and much more.

k3s runs on 3 nodes:
- **k3s-server**: the "brain" — makes all decisions, stores cluster state
- **k3s-agent-1** and **k3s-agent-2**: the "workers" — actually run the containers

Not familiar with Kubernetes or k3s? See the [Kubernetes/k3s technology guide](./technologies/kubernetes-k3s.md).

---

## Why Flannel Over Tailscale?

k3s uses a networking layer called **Flannel** to route traffic between containers
on different nodes. Flannel normally uses the node's main LAN IP address.

**The problem:** Home LAN IPs can change if the router hands out new DHCP leases.
When a node's IP changes, Flannel's internal networking tables become outdated and
pods stop being able to communicate.

**The solution:** Configure Flannel to use the Tailscale interface (`tailscale0`)
instead of the LAN interface. Tailscale IPs (`100.x.x.x`) never change as long as
the device is enrolled in the tailnet.

For detailed explanation, see [Flannel over Tailscale](../flannel-over-tailscale.md).

---

## 4.1 Option A — Via GitHub Actions (Recommended)

### Step 1: Deploy the k3s Server

1. Go to **Actions → Ansible - Deploy k3s → Run workflow**
2. Set `target_host = k3s-server`
3. Click **Run workflow**

**What this does:**
- Connects to `k3s-server.tailnet.ts.net` via Tailscale SSH
- Retrieves the node's Tailscale IP (`tailscale ip -4`)
- Writes `/etc/rancher/k3s/config.yaml`:
  ```yaml
  write-kubeconfig-mode: "644"
  tls-san:
    - "k3s-server"
    - "<tailscale-ip>"
  node-ip: "<tailscale-ip>"
  flannel-iface: tailscale0
  ```
- Installs k3s server via the official install script
- Waits for the node to show `Ready` status

**What is `config.yaml`?**  
This file tells k3s how to configure itself when it starts:
- `tls-san`: Extra DNS names that are valid for the Kubernetes API certificate
  (allows connecting by hostname, not just IP)
- `node-ip`: Forces k3s to use the Tailscale IP instead of the LAN IP
- `flannel-iface`: Forces Flannel to use the `tailscale0` network interface

### Step 2: Deploy k3s Workers

Run **Actions → Ansible - Add k3s Worker Node (Tailscale)** twice:

| Run | Input: `worker_host` | Input: `server_host` |
|-----|---------------------|---------------------|
| 1st run | `k3s-agent-1` | `k3s-server` |
| 2nd run | `k3s-agent-2` | `k3s-server` |

**What this does for each worker:**
- Fetches the node token from `/var/lib/rancher/k3s/server/node-token` on the server
- Sets the server URL: `K3S_URL=https://k3s-server.tailnet.ts.net:6443`
- Connects to the worker node via Tailscale SSH
- Retrieves the worker's Tailscale IP
- Writes `/etc/rancher/k3s/config.yaml` with Tailscale IP configuration
- Installs the k3s agent and joins it to the cluster

---

## 4.2 Option B — Manual Ansible

Use this if GitHub Actions is unavailable.

```bash
# Install Ansible
pip install ansible

# Ensure you are on the tailnet
tailscale up

# Add the k3s-server host key to known_hosts (find this in .ssh/known_hosts in the repo)
echo "k3s-server.tailnet.ts.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDY0q2U6SakvDe1Fo7/EX4FrT+alwv1zv7eQtyxchMGa" >> ~/.ssh/known_hosts
```

```bash
# Create Ansible inventory file for the server
cat > /tmp/inventory-server.yml <<EOF
---
all:
  children:
    k3s:
      hosts:
        k3s-server:
          ansible_host: k3s-server.tailnet.ts.net
          ansible_user: ubuntu
          ansible_ssh_common_args: '-o StrictHostKeyChecking=yes'
      vars:
        ansible_python_interpreter: /usr/bin/python3
EOF

# Navigate to the Ansible directory
cd /path/to/homelab/ansible

# Deploy the k3s server
ansible-playbook playbooks/deploy_k3s.yml -i /tmp/inventory-server.yml
```

```bash
# Get the cluster join token from the server
TOKEN=$(ssh ubuntu@k3s-server.tailnet.ts.net \
  "sudo cat /var/lib/rancher/k3s/server/node-token")
K3S_URL="https://k3s-server.tailnet.ts.net:6443"
echo "Token: $TOKEN"
```

```bash
# Deploy agent-1
cat > /tmp/inventory-agent1.yml <<EOF
---
all:
  children:
    k3s_workers:
      hosts:
        k3s-agent-1:
          ansible_host: k3s-agent-1.tailnet.ts.net
          ansible_user: ubuntu
      vars:
        ansible_python_interpreter: /usr/bin/python3
EOF

K3S_TOKEN="$TOKEN" K3S_URL="$K3S_URL" \
  ansible-playbook playbooks/deploy_k3s_worker_tailscale.yml \
  -i /tmp/inventory-agent1.yml
```

```bash
# Deploy agent-2
cat > /tmp/inventory-agent2.yml <<EOF
---
all:
  children:
    k3s_workers:
      hosts:
        k3s-agent-2:
          ansible_host: k3s-agent-2.tailnet.ts.net
          ansible_user: ubuntu
      vars:
        ansible_python_interpreter: /usr/bin/python3
EOF

K3S_TOKEN="$TOKEN" K3S_URL="$K3S_URL" \
  ansible-playbook playbooks/deploy_k3s_worker_tailscale.yml \
  -i /tmp/inventory-agent2.yml
```

---

## 4.3 Apply the Tailscale Startup Ordering Fix

> ⚠️ **Required after every fresh k3s deployment.** Without this, k3s nodes may fail to
> initialize Flannel correctly after a reboot, causing pods on different nodes to lose
> network connectivity.

**The problem:** On reboot, k3s starts before Tailscale finishes connecting. When
k3s starts and Tailscale isn't ready yet, Flannel can't bind to `tailscale0` and
creates a broken network setup.

**The fix:** A systemd "drop-in" file that makes the k3s service wait for Tailscale
to be fully connected before starting.

```bash
# Via GitHub Actions (recommended):
# Actions → Ansible - Fix k3s Tailscale Startup Order → Run workflow
# Leave target_hosts as default: k3s-server,k3s-agent-1,k3s-agent-2
```

**What this creates on each node:**

```ini
# /etc/systemd/system/k3s.service.d/after-tailscale.conf
# (k3s-agent.service.d/after-tailscale.conf on worker nodes)
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/bin/sh -c 'until ip addr show tailscale0 2>/dev/null | grep -q "inet 100\."; do sleep 2; done'
```

This causes k3s to:
1. Start only after the `tailscaled` service has started
2. Poll every 2 seconds until `tailscale0` shows a valid `100.x.x.x` IP address before proceeding

**Reference:** [Flannel over Tailscale](../flannel-over-tailscale.md) for full explanation
of the race condition and manual recovery commands.

---

## 4.4 Install Longhorn Prerequisites

Longhorn is the distributed storage system used by Kubernetes workloads (databases,
persistent data). It requires some packages to be installed on all nodes before it can work.

```bash
# Via GitHub Actions (recommended):
# Actions → Ansible - Install Longhorn Prerequisites → Run workflow
```

**What this installs on each node:**
- `open-iscsi` — block storage protocol used by Longhorn
- `nfs-common` — NFS client for potential NFS mounts
- `util-linux` — system utilities
- Loads the `iscsi_tcp` kernel module

Not familiar with Longhorn? See the [Longhorn technology guide](./technologies/longhorn.md).

---

## 4.5 Verify Cluster Health

SSH to the k3s server and confirm all nodes are Ready:

```bash
ssh ubuntu@k3s-server.tailnet.ts.net

# Check all nodes
sudo kubectl get nodes -o wide
```

**Expected output:**
```
NAME          STATUS   ROLES                  AGE   VERSION   INTERNAL-IP       EXTERNAL-IP   ...
k3s-server    Ready    control-plane,master   5m    v1.x.x    100.94.165.115    <none>        ...
k3s-agent-1   Ready    <none>                 3m    v1.x.x    100.110.221.27    <none>        ...
k3s-agent-2   Ready    <none>                 3m    v1.x.x    100.103.36.18     <none>        ...
```

> **Key:** All `INTERNAL-IP` values should be Tailscale addresses (`100.x.x.x`).
> If they show LAN IPs (`192.168.1.x`), the flannel-iface config was not applied.
> Re-run the k3s deployment Ansible playbook.

**Verify all system pods are running:**
```bash
sudo kubectl get pods -A
```

Look for all pods in `kube-system` namespace to be `Running` or `Completed`.

---

## 4.6 Configure Local kubectl Access (Optional)

If you want to run `kubectl` commands from your laptop instead of SSHing to the server:

```bash
# Copy kubeconfig from the server
scp ubuntu@k3s-server.tailnet.ts.net:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-config

# Update the server address to the Tailscale hostname
sed -i 's|https://127.0.0.1:6443|https://k3s-server.tailnet.ts.net:6443|' \
  ~/.kube/k3s-config

# Use this kubeconfig
export KUBECONFIG=~/.kube/k3s-config

# Verify it works
kubectl get nodes
```

> **What is kubeconfig?**  
> A kubeconfig file tells `kubectl` where to find the Kubernetes API server and how
> to authenticate. By default, k3s stores it at `/etc/rancher/k3s/k3s.yaml` on the server.
> The file contains a client certificate and private key.

---

## Summary Checklist

Before proceeding to Phase 5:

- [ ] k3s server deployed — visible in `kubectl get nodes` as `Ready`
- [ ] k3s-agent-1 joined and shows as `Ready` in `kubectl get nodes`
- [ ] k3s-agent-2 joined and shows as `Ready` in `kubectl get nodes`
- [ ] All nodes show Tailscale IPs (`100.x.x.x`) as their INTERNAL-IP
- [ ] Tailscale startup fix applied to all 3 nodes
- [ ] Longhorn prerequisites installed on all nodes
- [ ] All `kube-system` pods are `Running`

---

## Proceed to Phase 5

→ [Phase 5: Flux Bootstrap](./05-flux-bootstrap.md)
