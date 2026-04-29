# Phase 7: Validation

> **Time estimate:** ~15 minutes
>
> Work through this checklist from top to bottom to confirm a successful recovery.
> Every item must pass before the homelab is considered fully restored.

---

## 7.1 Kubernetes Nodes

All 3 nodes must be `Ready` with Tailscale IPs:

```bash
sudo kubectl get nodes -o wide
```

**Expected output:**
```
NAME          STATUS   ROLES                  AGE   VERSION   INTERNAL-IP       EXTERNAL-IP
k3s-server    Ready    control-plane,master   Xm    v1.x.x    100.94.165.115    <none>
k3s-agent-1   Ready    <none>                 Xm    v1.x.x    100.110.221.27    <none>
k3s-agent-2   Ready    <none>                 Xm    v1.x.x    100.103.36.18     <none>
```

✅ **Pass:** All 3 nodes `Ready`, all `INTERNAL-IP` values start with `100.`  
❌ **Fail — LAN IPs shown:** Re-run the k3s Ansible playbook (the `flannel-iface` config was not applied)  
❌ **Fail — node not Ready:** Check node logs: `sudo kubectl describe node <name>`

---

## 7.2 Flux Kustomizations

All managed Kustomizations must be `Ready`:

```bash
flux get kustomizations -n flux-system
# Or with kubectl:
kubectl get kustomizations -n flux-system
```

**Expected output:**
```
NAME            READY   STATUS
flux-system     True    Applied revision: main@sha1:...
apps            True    Applied revision: main@sha1:...
adguard         True    Applied revision: main@sha1:...
authentik       True    Applied revision: main@sha1:...
...
```

**Investigate a failing kustomization:**
```bash
flux get kustomization <name> -n flux-system --verbose
kubectl describe kustomization <name> -n flux-system
# Look at the "Message" field for error details
```

**Force reconciliation:**
```bash
flux reconcile kustomization <name> -n flux-system
```

---

## 7.4 Cloudflare DNS Records and Tunnel

Log in to [dash.cloudflare.com](https://dash.cloudflare.com) and confirm the zone for
`example.com` is active. All DNS records are managed by OpenTofu — running `tofu apply`
recreates them. Verify these are present:

| Record | Type | Value |
|--------|------|-------|
| `mail.example.com` | CNAME | `<tunnel-id>.cfargotunnel.com` (proxied) |
| `status.example.com` | CNAME | `<tunnel-id>.cfargotunnel.com` (proxied) |
| `resend._domainkey.example.com` | TXT | DKIM key from Resend dashboard |
| `send.example.com` | MX | `feedback-smtp.us-east-1.amazonses.com` |
| `send.example.com` | TXT | `v=spf1 include:amazonses.com ~all` |
| `_dmarc.example.com` | TXT | `v=DMARC1; p=none;` |

**Verify the Cloudflare Tunnel is connected:**
```bash
kubectl logs -n cloudflared deployment/cloudflared --since=5m | grep -E "connect|registered|error"
# Should show: "Connection registered" — no errors
```

**Verify Email Routing is enabled** (inbound mail forwarding):

1. Cloudflare dashboard → the `example.com` zone → Email → Email Routing
2. Confirm status shows **Enabled**
3. Confirm destination `admin@example.com` shows **Verified**
   - If Unverified: click the address and resend the verification email

✅ **Pass:** Tunnel connected, DNS records present, Email Routing enabled and verified
❌ **Fail — tunnel not connected:** Check `cloudflared-tunnel-credentials` secret was patched (Phase 6.2)

---

## 7.5 MetalLB Load Balancer

MetalLB provides LoadBalancer-type IP addresses from the LAN IP pool `192.168.1.230–192.168.1.250`:

```bash
# Check MetalLB pods are running
sudo kubectl -n metallb-system get pods
```

**Expected:**
```
NAME                          READY   STATUS    RESTARTS
controller-<hash>             1/1     Running   0
speaker-<hash>                1/1     Running   0
speaker-<hash>                1/1     Running   0
speaker-<hash>                1/1     Running   0
```

```bash
# Verify the IP address pool is configured
sudo kubectl -n metallb-system get ipaddresspool
```

Expected: A pool covering `192.168.1.230–192.168.1.250` with status `Auto Assigned`.

---

## 7.6 Cross-Node Pod Communication (Flannel Health)

Verify Flannel over Tailscale is working by testing cross-node DNS resolution:

```bash
# Launch a temporary test pod and run a DNS lookup
sudo kubectl run dnstest \
  --image=busybox:1.35 \
  --restart=Never \
  --rm \
  -it \
  -- nslookup kubernetes.default.svc.cluster.local
```

**Expected output:**
```
Server:    10.43.0.10
Address 1: 10.43.0.10 kube-dns.kube-system.svc.cluster.local

Name:      kubernetes.default.svc.cluster.local
Address 1: 10.43.0.1 kubernetes.default.svc.cluster.local
```

✅ **Pass:** DNS resolves successfully  
❌ **Fail — command hangs:** Flannel VXLAN is broken

**If DNS hangs, investigate Flannel:**
```bash
# Check Flannel is using tailscale0
sudo kubectl -n kube-system logs -l app=flannel --tail=30 | grep -E "tailscale|iface"

# On any affected node, check if flannel.1 interface exists
# (run via kubectl debug or node SSH)
ssh ubuntu@k3s-agent-1.tailnet.ts.net "ip link show flannel.1"
```

If `flannel.1` is missing, see the [Flannel over Tailscale](../flannel-over-tailscale.md) guide
for the manual recovery procedure.

---

## 7.7 Tailscale Operator

```bash
# Check the operator is running
sudo kubectl -n tailscale get pods
# All pods: Running

# Check that the operator is connected to the tailnet
sudo kubectl -n tailscale logs -l app=operator --tail=20
# Should show: "logged in" or "reconciling" — not authentication errors

# Verify a Tailscale ingress has an address assigned (e.g. Authentik)
sudo kubectl -n authentik get ingress authentik -o jsonpath='{.status.loadBalancer}'
```

---

## 7.8 Longhorn Storage

```bash
# Check all Longhorn pods are running
sudo kubectl -n longhorn-system get pods
# All should show Running or Completed

# Check Longhorn nodes (should show all 3 k3s nodes)
sudo kubectl -n longhorn-system get nodes.longhorn.io
```

Expected: All 3 nodes listed with `READY=True` and conditions showing healthy disk and
networking status.

**Access Longhorn UI** (if the Longhorn dashboard ingress is configured):
- Should be accessible via Tailscale at a URL defined in `k3s/manifests/`

**Reference:** [Longhorn documentation](https://longhorn.io/docs/)

---

## 7.9 AWS S3 Backups

```bash
# Verify the S3 bucket is accessible
aws s3 ls s3://<S3_BACKUP_BUCKET_NAME> --region us-east-1

# If the bucket has existing backups, verify their integrity
aws s3 ls s3://<S3_BACKUP_BUCKET_NAME>/ --recursive --human-readable
```

✅ **Pass:** Bucket is accessible and lists backup objects  
❌ **Fail — access denied:** Check AWS credentials are correct  
❌ **Fail — bucket not found:** Run `tofu apply` to recreate the bucket

---

## 7.10 cert-manager

```bash
# ClusterIssuer must be Ready
kubectl get clusterissuer letsencrypt-production -o jsonpath='{.status.conditions[0].message}'
# Expected: "The ACME account was registered with the ACME server"

# Verify no certificates are failing
kubectl get certificates --all-namespaces | grep -v "True\|Ready"
# No output means all certs are issued
```

✅ **Pass:** ClusterIssuer Ready, no failed certificates  
❌ **Fail — ACME registration failing:** Check cert-manager logs (`kubectl logs -n cert-manager deployment/cert-manager`)  
❌ **Fail — certificate not issued:** Cloudflare Tunnel must be working first (Section 7.4) so HTTP-01 challenges can reach the cluster

---

## 7.11 Authentik SSO

```bash
# Pods should be running
kubectl get pods -n authentik
# Expected: authentik-server-*, authentik-worker-*, postgresql-* all Running

# Check server is healthy
kubectl logs -n authentik deployment/authentik-server --since=2m | grep -i error | tail -5
# Should be empty (no errors)
```

**Log in to Authentik:**

1. Open `https://authentik.tailnet.ts.net`
2. Log in as `akadmin` with the bootstrap password (from Phase 6.3)
3. Navigate to **Applications → Applications** — verify your configured apps are listed
4. Navigate to **Applications → Outposts** — verify the Embedded Outpost shows as healthy

!!! warning "If applications are missing"
    Authentik application/provider config is stored in its PostgreSQL database. If the CNPG
    cluster PVC survived, the config is intact. If the PVC was wiped, you need to manually
    recreate providers and applications — see `docs/authentik.md` for the procedure.

✅ **Pass:** Both pods Running, UI accessible, apps and outpost present  
❌ **Fail — pods CrashLoopBackOff:** Usually a bad `secret-key` — verify `authentik-credentials` was patched (Phase 6.3)  
❌ **Fail — database connection refused:** CNPG cluster may need time to come up; wait 5 minutes and retry

---

## 7.12 Stalwart Email Server

```bash
# Pod should be running
kubectl get pods -n stalwart
# Expected: stalwart-* Running

# Check logs for startup errors
kubectl logs -n stalwart deployment/stalwart --since=2m | grep -iE "error|panic|failed" | head -10
# Should be empty
```

**Log in to the admin UI:**

1. Open `https://mail.tailnet.ts.net`
2. Log in as `admin` with the password from Phase 6.4
3. Navigate to **Directory → Accounts** — verify `noreply@example.com` exists

**Send a test email through Authentik:**
```bash
kubectl exec -n authentik deployment/authentik-worker -- ak test_email admin@example.com 2>&1 | \
  grep -E "email_sent|error" | tail -3
# Expected: "message": "Email to admin@example.com sent"
```

Check `admin@example.com` inbox (or Resend dashboard at resend.com) to confirm delivery.

✅ **Pass:** Pod running, admin UI accessible, test email delivered  
❌ **Fail — pod not starting:** Check `stalwart-secrets` was patched (Phase 6.4); check logs for config parse errors  
❌ **Fail — auth rejected (535):** SMTP username must be `noreply` (short form), not `noreply@example.com`  
❌ **Fail — email not delivered:** Check Resend dashboard for bounces; verify `resend-api-key` is correct

---

## 7.13 Full End-to-End Test

The ultimate test: make a change to the GitHub repository and verify Flux applies it automatically.

```bash
# On your laptop (or any machine with git and kubectl)
# 1. Make a trivial change to a manifest (e.g., add a harmless annotation)
# 2. Commit and push to main
git add . && git commit -m "test: validate Flux reconcile" && git push origin main

# 3. Wait ~10 minutes for Flux to poll (or force immediately):
flux reconcile source git homelab -n flux-system
flux reconcile kustomization apps -n flux-system

# 4. Verify the change was applied
sudo kubectl get <resource> -n <namespace> -o yaml | grep <your-annotation>
```

✅ **Pass:** Change appears in the cluster within 10 minutes  
❌ **Fail:** Check `flux get sources git -n flux-system` and verify the SSH deploy key is correct

---

## Recovery Complete! 🎉

If all checks above pass, the homelab has been successfully recovered.

**Final checklist:**

- [ ] All 3 k3s nodes are `Ready` with Tailscale IPs
- [ ] All Flux Kustomizations are `Ready`
- [ ] Cloudflare Tunnel connected, public services (`mail.example.com`, `status.example.com`) accessible
- [ ] Cloudflare Email Routing enabled and destination address verified
- [ ] cert-manager ClusterIssuer Ready, TLS certificates issued
- [ ] MetalLB IP pool is configured
- [ ] Cross-node pod DNS resolution works
- [ ] Tailscale operator is running and authenticated
- [ ] Longhorn storage nodes are healthy
- [ ] Authentik UI accessible, applications and outpost configured
- [ ] Stalwart admin UI accessible at `mail.tailnet.ts.net`
- [ ] Test email sends successfully via Authentik → Stalwart → Resend
- [ ] S3 bucket is accessible
- [ ] Flux auto-reconciles a test commit from GitHub

---

## Post-Recovery Tasks

1. **Clean up old Tailscale devices** from the previous installation:
   - Go to [login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
   - Delete any offline devices from the old installation

2. **Verify Cloudflare Email Routing destination** is still verified (check Cloudflare dashboard → Email Routing)

3. **Verify backup schedule** is running on the game server:
   ```bash
   ssh ubuntu@game-server.tailnet.ts.net
   sudo systemctl status minecraft-backup.timer
   ```

4. **Document any issues** encountered during recovery in the GitHub repository
   (create an issue or update this guide)

---

## Common Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Nodes show LAN IPs | `flannel-iface` not set | Re-run k3s Ansible playbook |
| Flux kustomizations stuck reconciling | SSH deploy key wrong | Re-create `flux-system` Git credentials |
| Tailscale devices not appearing | Tailscale auth key expired | Generate new key via OpenTofu |
| MetalLB not assigning IPs | L2Advertisement not reconciled | `flux reconcile kustomization metallb-config -n flux-system` |
| DNS test pod hangs | Flannel VXLAN broken | See [Flannel over Tailscale](../flannel-over-tailscale.md) |
| Tailscale operator auth errors | OAuth secret not applied | Complete Phase 6.1 |
| Longhorn volumes degraded | Node count changed | Allow time for replica rebalancing |
| Cloudflare Tunnel offline | Tunnel token not patched | Complete Phase 6.2 |
| Authentik CrashLoopBackOff | `secret-key` wrong/missing | Complete Phase 6.3 |
| Stalwart SMTP 535 errors | Username is full email not short name | Use `noreply` not `noreply@example.com` |
| Emails not relayed (direct MX) | Resend API key wrong or routing config missing | Check `queue.strategy.route` in configmap, check DB overrides |
