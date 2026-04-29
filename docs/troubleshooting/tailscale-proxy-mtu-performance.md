# Tailscale Proxy Performance Degradation (MTU / Double-Tunneling)

## Symptoms

- Noticeably slow response times through all Tailscale-exposed services (Ingresses, Funnel)
- Throughput is significantly worse when measured through the Tailscale operator proxy pods compared to direct connections
- High packet counts / retransmissions visible in `tcpdump` or `netstat -s`
- Large number of dropped RX packets on `eth0` (`ip -s link show eth0`)

---

## Root Cause

### The MTU cascade

When `flannel-iface: tailscale0` is set on all nodes, Kubernetes pod networking (Flannel VXLAN) runs **on top of** the Tailscale WireGuard tunnel:

```
Pod data → Flannel VXLAN (+50 bytes) → Tailscale WireGuard (+80 bytes) → eth0 (MTU 1500)
```

Flannel auto-detects the `tailscale0` MTU (1280) and subtracts VXLAN overhead to set the pod MTU:

```
1280 (tailscale0 MTU) − 50 (VXLAN overhead) = 1230 (pod MTU)
```

### Why proxy pods make it worse

The Tailscale operator proxy pods (`ts-*`) run their own `tailscaled` instance in userspace mode (`--tun=userspace-networking`). These pods are themselves Tailscale network devices — traffic flowing *through* them gets a **third** layer of WireGuard encapsulation:

```
data → pod WireGuard (−80 bytes) → Flannel VXLAN (−50 bytes) → host WireGuard (−80 bytes) → eth0
```

Effective payload MTU through a proxy pod:

| Configuration | Effective Payload MTU | % of normal |
|---|---|---|
| Direct Tailscale connection | ~1420 bytes | 100% |
| **flannel-iface: tailscale0** (broken) | ~**1150** bytes | **~81%** |
| flannel-iface: eth0 (fixed) | ~1370 bytes | ~96% |

The ~270 byte reduction with `tailscale0` forces TCP to use a much smaller MSS, increases packet counts for the same data, and causes IP-level fragmentation — all of which degrade throughput significantly.

---

## Diagnosis

### 1. Check the flannel MTU

```bash
cat /run/flannel/subnet.env
# Healthy:   FLANNEL_MTU=1450
# Degraded:  FLANNEL_MTU=1230
```

```bash
ip link show flannel.1 | grep mtu
# Healthy:   mtu 1450
# Degraded:  mtu 1230
```

### 2. Check pod MTU

```bash
kubectl run mtu-test --image=busybox --restart=Never --rm -it --command -- ip link show eth0
# Healthy:  mtu 1450
# Degraded: mtu 1230
```

### 3. Check for the double-tunnel config

```bash
grep flannel-iface /etc/rancher/k3s/config.yaml
# Degraded: flannel-iface: tailscale0
# Fixed:    flannel-iface: eth0
```

On agent nodes (via `kubectl debug`):
```bash
kubectl debug node/k3s-agent-2 --image=ubuntu -- bash -c \
  "grep flannel-iface /host/etc/rancher/k3s/config.yaml"
```

### 4. Confirm proxy pods are in userspace mode

```bash
kubectl exec -n tailscale <ts-pod> -- ps aux | grep tailscaled
# Will show: --tun=userspace-networking  (this is normal, not the issue)
```

The userspace mode is expected and required for pods. The problem is the pod MTU the userspace Tailscale is working within, not the networking mode itself.

---

## Fix

Change `flannel-iface` from `tailscale0` to `eth0` on all nodes. The node still registers with its Tailscale IP (via `node-ip`) for stability — only the Flannel VXLAN data plane moves to the faster LAN interface.

!!! note "Why eth0 is safe here"
    Flannel VXLAN will now use LAN IPs (192.168.1.x) instead of Tailscale IPs. Kubernetes node registration still uses the stable Tailscale IP via `node-ip`, so the control plane is unaffected. As long as LAN IPs are stable (static or DHCP-reserved), flannel connectivity between nodes is reliable.

    If a node's LAN IP ever changes, run the fix below again. For the primary failure mode (DHCP churn breaking flannel), see [flannel-over-tailscale.md](../flannel-over-tailscale.md).

### On the server node

```bash
sudo sed -i 's/flannel-iface: tailscale0/flannel-iface: eth0/' \
  /etc/rancher/k3s/config.yaml

sudo systemctl restart k3s
```

### On agent nodes (no direct SSH — use `kubectl debug`)

```bash
for node in k3s-agent-1 k3s-agent-2; do
  kubectl debug node/$node --image=ubuntu -- bash -c \
    "sed -i 's/flannel-iface: tailscale0/flannel-iface: eth0/' \
     /host/etc/rancher/k3s/config.yaml && \
     grep flannel-iface /host/etc/rancher/k3s/config.yaml"
  echo "--- $node updated ---"
done
```

Restart each agent:
```bash
for node in k3s-agent-1 k3s-agent-2; do
  kubectl debug node/$node --image=ubuntu -- \
    chroot /host systemctl restart k3s-agent
done
```

Wait ~30 seconds, then verify nodes are `Ready`:
```bash
kubectl get nodes
```

### Update cni0 and restart proxy pods

After k3s restarts, `flannel.1` immediately gets the correct MTU (1450). However the `cni0` bridge persists with its old MTU until manually updated:

```bash
# On the server node
sudo ip link set cni0 mtu 1450

# On agent nodes
for node in k3s-agent-1 k3s-agent-2; do
  kubectl debug node/$node --image=ubuntu -- \
    chroot /host ip link set cni0 mtu 1450
done
```

Bounce the Tailscale proxy pods so they get new veth pairs at the correct MTU:
```bash
kubectl delete pods -n tailscale \
  $(kubectl get pods -n tailscale --no-headers -o name | \
    grep -v operator | xargs -I{} basename {})
```

### Verify

```bash
# flannel subnet should now report 1450
cat /run/flannel/subnet.env
# FLANNEL_MTU=1450

# New pods should show 1450
kubectl run mtu-test --image=busybox --restart=Never --rm -it --command -- \
  ip link show eth0
# mtu 1450 ✓

# Proxy pods should show 1450
for pod in $(kubectl get pods -n tailscale --no-headers -l '' -o name | grep ts-); do
  echo -n "$pod: "
  kubectl exec -n tailscale $(basename $pod) -- ip link show eth0 2>/dev/null | \
    grep -o 'mtu [0-9]*'
done
```

---

## Expected MTU Values After Fix

| Interface | Node MTU | Notes |
|---|---|---|
| `eth0` | 1500 | Physical NIC, unchanged |
| `tailscale0` | 1280 | Tailscale WireGuard, unchanged |
| `flannel.1` | **1450** | VXLAN over eth0 (was 1230) |
| `cni0` | **1450** | Bridge for pods (was 1230) |
| Pod `eth0` | **1450** | Container interfaces (was 1230) |
| Effective payload through proxy pod | **~1370** | WireGuard overhead on 1450 (was ~1150) |

---

## Related Issue: TLS Cipher Mismatch on Funnel

While investigating this, the authentik proxy pod was also logging TLS handshake failures:

```
http: TLS handshake error: tls: no cipher suite supported by both client and server
```

This affects legacy clients (e.g., old TLS 1.2-only clients) connecting via Tailscale Funnel. The Tailscale proxy uses a restricted cipher suite list by default. This is a separate issue from the MTU degradation but surfaces as connection failures rather than slow connections.

---

## See Also

- [Flannel over Tailscale](../flannel-over-tailscale.md) — full design doc for the flannel/Tailscale integration
- [Tailscale Operator](../tailscale-operator.md) — how proxy pods are provisioned
