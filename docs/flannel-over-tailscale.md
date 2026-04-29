# Flannel over Tailscale

## Overview

By default k3s uses Flannel VXLAN with each node's LAN IP as the VTEP (tunnel endpoint). If DHCP reassigns a node's IP, the other nodes' forwarding database (fdb) tables go stale and cross-node pod traffic silently drops — causing DNS timeouts, Flux reconciliation failures, and general cluster instability.

The primary fix is to set `node-ip` to the node's Tailscale IP. Tailscale IPs (`100.x.x.x`) are assigned by the Tailscale control plane and **never change**, regardless of what DHCP does to the LAN interfaces. This ensures the Kubernetes control plane and node registration always use stable IPs.

For the Flannel VXLAN **data plane**, this cluster uses `flannel-iface: eth0` (the LAN interface) rather than `tailscale0`. This is an intentional performance trade-off — see [Flannel iface trade-off](#flannel-iface-trade-off) below.

```
Node registration:  100.x.x.x  (Tailscale IP — stable, via node-ip flag)
Flannel data plane: 192.168.1.x (LAN IP — fast, via flannel-iface: eth0)
```

---

## Current Node IPs

| Node | LAN IP | Tailscale IP |
|------|--------|-------------|
| k3s-server | 192.168.1.179 | 100.94.165.115 |
| k3s-agent-1 | 192.168.1.175 | 100.110.221.27 |
| k3s-agent-2 | 192.168.1.180 | 100.103.36.18 |

---

## How It Works

### The config

Each node has `/etc/rancher/k3s/config.yaml` written before k3s starts:

**Server (`k3s-server`):**
```yaml
write-kubeconfig-mode: "644"
tls-san:
  - k3s-server.tailnet.ts.net
  - 100.94.165.115
  - 192.168.1.179
node-ip: "100.94.165.115"
flannel-iface: eth0
```

**Agents (`k3s-agent-1`, `k3s-agent-2`):**
```yaml
node-ip: "100.x.x.x"
node-external-ip: "100.x.x.x"
flannel-iface: eth0
```

### What each flag does

| Flag | Effect |
|------|--------|
| `flannel-iface: eth0` | Flannel binds its VXLAN VTEP to the LAN interface for the data plane |
| `node-ip` | The IP the node advertises to the API server and Flannel — set to Tailscale IP for stability |
| `node-external-ip` | The externally-routable IP for the node (agents only) |
| `tls-san` | Adds the Tailscale IP to the API server's TLS certificate (server only) |

### What happens at the kernel level

Flannel maintains a forwarding database (fdb) entry per remote node. With `flannel-iface: eth0`, VXLAN packets are sent directly to LAN IPs:
```
# fdb entries point at LAN IPs (fast, direct)
bridge fdb show dev flannel.1
aa:bb:cc:dd:ee:01 dst 192.168.1.175 self permanent
```

The Kubernetes node registration (control plane routing, `kubectl`, etc.) still uses Tailscale IPs because `node-ip` is set to `100.x.x.x`. If the LAN IP changes, only the Flannel data plane is affected — the cluster control plane remains healthy.

---

## Flannel iface trade-off

### Why not `flannel-iface: tailscale0`?

An earlier version of this cluster used `flannel-iface: tailscale0`, which routes all Flannel VXLAN traffic through the Tailscale WireGuard tunnel. While this encrypts inter-node pod traffic, it creates a severe MTU cascade when combined with the Tailscale operator:

```
tailscale0 MTU 1280 − 50 (VXLAN) = pod MTU 1230
```

The Tailscale operator proxy pods run their own `tailscaled` inside them — a second layer of WireGuard on top of the already-encapsulated pod network. This **triple-encapsulates** every proxied packet:

```
data → pod WireGuard → Flannel VXLAN → host WireGuard → eth0
```

Effective payload MTU dropped to ~1150 bytes vs the expected ~1420, causing significant IP fragmentation and throughput degradation on all Tailscale-exposed services.

See [Tailscale Proxy Performance Degradation](troubleshooting/tailscale-proxy-mtu-performance.md) for the full diagnosis and fix.

### Current trade-off

| Concern | `flannel-iface: tailscale0` | `flannel-iface: eth0` (current) |
|---|---|---|
| Stable node IPs | ✅ (via tailscale0) | ✅ (via `node-ip: 100.x.x.x`) |
| Pod MTU | 1230 | **1450** |
| Inter-node traffic encrypted | ✅ WireGuard | ❌ Plain VXLAN on LAN |
| Tailscale proxy throughput | Degraded (triple-tunnel) | **Normal** |
| Breaks if LAN IP changes | No | Yes — restart k3s-agent |

**Best practice:** Ensure LAN IPs are static or DHCP-reserved so Flannel's fdb table stays valid. See [Provisioning New Nodes](#provisioning-new-nodes).

---

## Verifying the Configuration

### Check node registration IPs
```bash
kubectl get nodes -o json | jq -r '.items[] | 
  .metadata.name + 
  "  internal=" + .metadata.annotations["k3s.io/internal-ip"] + 
  "  flannel=" + .metadata.annotations["flannel.alpha.coreos.com/public-ip"]'
```

Expected output — all IPs should be `100.x.x.x`:
```
k3s-agent-1  internal=100.110.221.27  flannel=100.110.221.27
k3s-agent-2  internal=100.103.36.18   flannel=100.103.36.18
k3s-server   internal=100.94.165.115  flannel=100.94.165.115
```

### Test cross-node connectivity
```bash
# Run a pod and test DNS (which requires cross-node pod routing)
kubectl run dns-test --image=alpine --rm -it --restart=Never -- nslookup kubernetes.default.svc.cluster.local
```

### Check the fdb table on a node
```bash
# Via privileged nsenter pod on a node
kubectl debug node/k3s-server -it --image=alpine -- chroot /host bridge fdb show dev flannel.1
```

---

## Startup Ordering Fix

Flannel binds its VXLAN interface to `tailscale0` at k3s startup. If Tailscale hasn't fully connected yet, flannel silently fails to create the `flannel.1` interface — breaking all cross-node pod traffic until k3s is manually restarted.

### The Fix

A systemd drop-in is applied to all k3s nodes via the `fix_k3s_tailscale_startup.yml` Ansible playbook:

```ini
# /etc/systemd/system/k3s[-agent].service.d/after-tailscale.conf
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/bin/sh -c 'until ip addr show tailscale0 2>/dev/null | grep -q "inet 100\."; do echo "Waiting for tailscale0 interface..."; sleep 2; done'
```

This ensures:
1. systemd starts `tailscaled.service` before `k3s[-agent].service`
2. k3s blocks in `ExecStartPre` until `tailscale0` has a `100.x.x.x` IP — i.e., Tailscale is fully connected

Re-apply with the **Ansible - Fix k3s Tailscale Startup Order** GitHub Actions workflow.

### Symptoms of the Race Condition (Before Fix)

If the fix is missing and nodes reboot, you'll see:
- No `flannel.1` interface on the node: `ip link show flannel.1` → error
- DNS timeouts in all pods on that node: `lookup kubernetes.default.svc: i/o timeout`
- GitOps (Flux) resources showing errors
- Tailscale proxy pods (ts-*) in CrashLoopBackOff

### Emergency Manual Recovery

If the race condition strikes before the fix is applied, recreate flannel VXLAN manually (see also the node IPs/MACs table above):

```bash
# On the affected node (example: k3s-agent-2)
kubectl debug node/k3s-agent-2 -it --image=alpine -- chroot /host sh -c '
  ip link add flannel.1 type vxlan id 1 dstport 8472 local 192.168.1.180 nolearning
  ip link set flannel.1 address aa:bb:cc:dd:ee:03 mtu 1450 up
  # For each remote node:
  ip route add 10.42.0.0/24 via 10.42.0.0 dev flannel.1 onlink
  ip neigh add 10.42.0.0 lladdr aa:bb:cc:dd:ee:01 dev flannel.1 nud permanent
  bridge fdb append aa:bb:cc:dd:ee:01 dev flannel.1 dst 192.168.1.179
  ip route add 10.42.1.0/24 via 10.42.1.0 dev flannel.1 onlink
  ip neigh add 10.42.1.0 lladdr aa:bb:cc:dd:ee:02 dev flannel.1 nud permanent
  bridge fdb append aa:bb:cc:dd:ee:02 dev flannel.1 dst 192.168.1.175
'
```

VtepMACs (from node annotations `flannel.alpha.coreos.com/backend-data`):
| Node | LAN IP | Tailscale IP | VtepMAC | Pod CIDR |
|------|--------|-------------|---------|----------|
| k3s-server | 192.168.1.179 | 100.94.165.115 | aa:bb:cc:dd:ee:01 | 10.42.0.0/24 |
| k3s-agent-1 | 192.168.1.175 | 100.110.221.27 | aa:bb:cc:dd:ee:02 | 10.42.1.0/24 |
| k3s-agent-2 | 192.168.1.180 | 100.103.36.18 | aa:bb:cc:dd:ee:03 | 10.42.2.0/24 |

---

## Provisioning New Nodes

The Ansible playbooks handle this automatically. Before installing k3s, each playbook:

1. Gets the node's Tailscale IP: `tailscale ip -4`
2. Writes `/etc/rancher/k3s/config.yaml` with `flannel-iface: eth0`, `node-ip` set to the Tailscale IP, and any agent-specific flags
3. Installs k3s (which picks up the config file)

**Prerequisite:** Tailscale must be installed and authenticated on the node **before** running the k3s playbook so that `node-ip` (the Tailscale IP) resolves correctly at startup.

Relevant playbooks:
- `ansible/playbooks/deploy_k3s.yml` — server node
- `ansible/playbooks/deploy_k3s_worker_tailscale.yml` — worker joining via Tailscale network
- `ansible/playbooks/deploy_k3s_worker_local.yml` — worker joining via LAN (still uses Tailscale for Flannel)

---

## Applying the Change to an Existing Node

If you add a new node that wasn't provisioned with this config, or need to re-apply:

### 1. Write the config file

Use a privileged pod (replace IP and node name):
```bash
cat > /tmp/write-cfg.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: write-cfg
  namespace: default
spec:
  hostPID: true
  hostNetwork: true
  nodeName: k3s-agent-1          # <-- change this
  containers:
  - name: nsenter
    image: alpine
    command:
    - sh
    - -c
    - |
      nsenter -t 1 -m -u -i -n -- sh << 'SCRIPT'
      mkdir -p /etc/rancher/k3s
      cat > /etc/rancher/k3s/config.yaml << 'CONF'
      node-ip: "100.110.221.27"       # <-- Tailscale IP of this node
      node-external-ip: "100.110.221.27"
      flannel-iface: eth0
      CONF
      cat /etc/rancher/k3s/config.yaml
      SCRIPT
    securityContext:
      privileged: true
  restartPolicy: Never
EOF
kubectl apply -f /tmp/write-cfg.yaml
kubectl logs -f write-cfg
kubectl delete pod write-cfg
```

### 2. Restart k3s on the node

For agents:
```bash
cat > /tmp/restart.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: restart-k3s
  namespace: default
spec:
  hostPID: true
  hostNetwork: true
  nodeName: k3s-agent-1          # <-- change this
  containers:
  - name: nsenter
    image: alpine
    command: ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "systemctl", "restart", "k3s-agent"]
    securityContext:
      privileged: true
  restartPolicy: Never
EOF
kubectl apply -f /tmp/restart.yaml
```

For the server (kubectl will briefly disconnect and reconnect):
```bash
# Replace k3s-agent with k3s in the restart pod, nodeName: k3s-server
# command: [..., "systemctl", "restart", "k3s"]
```

### 3. Verify

```bash
sleep 30
kubectl get nodes -o json | jq -r '.items[] | .metadata.name + " flannel=" + .metadata.annotations["flannel.alpha.coreos.com/public-ip"]'
```

---

## Troubleshooting

### Node still showing LAN IP as its flannel IP

If the node registered before the config was written, it may have an old IP in the fdb. Force re-registration:
```bash
# Check the config was actually written
kubectl debug node/<node> -it --image=alpine -- chroot /host cat /etc/rancher/k3s/config.yaml

# If missing, re-apply the write-cfg pod above, then restart again
```

### Flannel performance is degraded (slow Tailscale proxy)

If pod MTU shows 1230 instead of 1450, or if Tailscale-proxied services are slow, the cluster may have been provisioned with `flannel-iface: tailscale0` (the previous configuration). See [Tailscale Proxy Performance Degradation](troubleshooting/tailscale-proxy-mtu-performance.md) for full diagnosis and the fix.

### Cross-node pods can't communicate after adding a node

If the new node's LAN IP differs from what other nodes have in their fdb, VXLAN packets will be misrouted. Check:
```bash
# On an agent node, check what IPs flannel knows about
kubectl debug node/k3s-agent-1 -it --image=alpine -- chroot /host bridge fdb show dev flannel.1

# If stale: restart k3s-agent on all nodes to force re-registration
```

### Verifying flannel data plane

```bash
# Check the fdb — entries should show LAN IPs (192.168.1.x)
kubectl debug node/k3s-server -it --image=alpine -- chroot /host bridge fdb show dev flannel.1

# Check the flannel MTU is 1450
cat /run/flannel/subnet.env
```

---

## Why Not Just Use Static LAN IPs?

Static LAN IPs (via OpenTofu cloud-init `ipconfig0`) are still worth having for human-readable addresses and direct SSH access. But as a solution to Flannel stability they have a weakness: if a VM is ever re-created (e.g., via `tofu apply` with `force_recreate`), the MAC address changes and the static lease may not match.

Tailscale IPs are assigned by identity (node key), not by MAC address or DHCP. They survive VM recreation as long as the Tailscale auth key or pre-auth key is the same device.

**Best practice:** Use both — static LAN IPs for convenience, Tailscale IPs for node registration (`node-ip`).
