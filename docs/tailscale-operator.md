# Tailscale Operator

This document covers the Tailscale Kubernetes operator deployed in this cluster: what it does, how credentials are managed, and how to expose services on the `your-tailnet` tailnet.

---

## Overview

The [Tailscale Kubernetes operator](https://tailscale.com/kb/1236/kubernetes-operator) runs in the `tailscale` namespace and acts as a bridge between Kubernetes resources and your Tailscale network. It watches for Services and Ingresses that request Tailscale exposure and provisions *proxy StatefulSets* that join the tailnet on their behalf.

In this cluster it is deployed via Flux CD using the official Helm chart:

| Item | Value |
|---|---|
| Chart | `tailscale-operator` |
| Version | `1.94.2` |
| Chart repo | `https://pkgs.tailscale.com/helmcharts` |
| Operator hostname (tailnet) | `k3s-tailscale-operator` |
| Namespace | `tailscale` |
| Flux HelmRelease | `tailscale-operator` (`tailscale.yaml`) |

### Node affinity

The operator is configured in `tailscale.yaml` with a `nodeAffinity` rule that prevents it from scheduling on `k3s-agent-1`.

```yaml
operatorConfig:
  hostname: k3s-tailscale-operator
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/hostname
                operator: NotIn
                values:
                  - k3s-agent-1
```

---

## Prerequisites: Tailscale ACL Tags

The operator uses OAuth credentials scoped to specific ACL tags. These tags must exist in your Tailscale ACL policy **before** installing the operator. In the `your-tailnet` tailnet the following tags are defined:

| Tag | Purpose |
|---|---|
| `tag:k8s-operator` | The operator pod itself |
| `tag:k8s` | Proxy pods (owned by `tag:k8s-operator`) |
| `tag:k8s-operator-proxy` | Alternative proxy tag if needed |

Relevant ACL snippet (for reference):

```json
"tagOwners": {
  "tag:k8s-operator": [],
  "tag:k8s":          ["tag:k8s-operator"],
  "tag:k8s-operator-proxy": ["tag:k8s-operator"]
}
```

---

## OAuth Credentials

### Why credentials are managed manually

The `operator-oauth` Secret in the `tailscale` namespace contains the OAuth `client_id` and `client_secret` that the operator uses to authenticate with Tailscale. These values must **never be committed to git**.

The git repo contains a *placeholder* secret (`k3s/manifests/tailscale/operator-oauth-secret.yaml`) with `REPLACE_ME` values so that Flux can create the Secret object. The secret carries the annotation `kustomize.toolkit.fluxcd.io/reconcile: disabled` so Flux will never overwrite real credentials with the placeholder:

```yaml
# operator-oauth-secret.yaml (excerpt)
metadata:
  annotations:
    kustomize.toolkit.fluxcd.io/reconcile: disabled
```

### One-time setup: creating the OAuth client

1. Go to <https://login.tailscale.com/admin/settings/oauth>.
2. Create a new OAuth client with:
   - **Scopes**: `devices:write`, `dns:read`, `dns:write`
   - **Tags**: `tag:k8s-operator`
3. Copy the `client_id` and `client_secret` — the secret is shown **once only**.

### Applying credentials to the cluster

Use `kubectl patch` (not `kubectl apply`) because the Secret was created via Flux's Server-Side Apply and a regular `apply` would conflict:

```bash
# Base64-encode your values first
CLIENT_ID_B64=$(echo -n "<your-client-id>" | base64)
CLIENT_SECRET_B64=$(echo -n "<your-client-secret>" | base64)

kubectl patch secret operator-oauth -n tailscale --type='json' -p="[
  {\"op\":\"replace\",\"path\":\"/data/client_id\",\"value\":\"${CLIENT_ID_B64}\"},
  {\"op\":\"replace\",\"path\":\"/data/client_secret\",\"value\":\"${CLIENT_SECRET_B64}\"}
]"
```

After patching, restart the operator so it picks up the new credentials:

```bash
kubectl rollout restart deployment -n tailscale -l app=operator
```

Verify the operator joined the tailnet by checking the Tailscale admin console — you should see a device named `k3s-tailscale-operator`.

---

## ProxyClass "prod"

The `prod` ProxyClass (defined in `k3s/manifests/tailscale/proxyclass-default.yaml`) configures all proxy pods to advertise the `tag:k8s-operator` tag:

```yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyClass
metadata:
  name: prod
spec:
  statefulSet:
    pod:
      tailscaleInitContainer:
        env:
          - name: TS_EXTRA_ARGS
            value: "--advertise-tags=tag:k8s-operator"
```

Reference this ProxyClass on any Service or Ingress that should use it:

```yaml
annotations:
  tailscale.com/proxy-class: "prod"
```

Using `prod` ensures proxy devices appear with the correct ACL tag in the Tailscale admin console and inherit the right ACL permissions.

---

## How Proxy Naming Works

When the operator provisions a proxy for a resource it creates a StatefulSet in the `tailscale` namespace named:

```
ts-<resource-name>-<hash>
```

For example, an Ingress named `myapp` in namespace `myapp` produces a pod like:

```
ts-myapp-myapp-<hash>-0
```

The device appears in the Tailscale admin console with the hostname you specified (e.g., `myapp`), not the StatefulSet name.

List proxy pods:

```bash
kubectl get pods -n tailscale
```

---

## Three Methods to Expose a Service

### Method 1: Annotate a ClusterIP Service

The operator watches for the `tailscale.com/expose: "true"` annotation and creates a proxy StatefulSet. The service becomes reachable at `<hostname>.tailnet.ts.net`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: my-namespace
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "my-service"   # tailnet hostname (defaults to service name)
    tailscale.com/proxy-class: "prod"      # use the prod ProxyClass
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
    - port: 8080
      targetPort: 8080
```

Use this method when you want raw TCP/UDP access or the service does not speak HTTP.

---

### Method 2: LoadBalancer with Tailscale class

Set `type: LoadBalancer` and `loadBalancerClass: tailscale`. The operator fulfils the LoadBalancer allocation by assigning a Tailscale IP instead of a bare-metal IP.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: my-namespace
  annotations:
    tailscale.com/hostname: "my-service"
    tailscale.com/proxy-class: "prod"
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

The `EXTERNAL-IP` field in `kubectl get svc` will show a Tailscale IP once the proxy is ready.

---

### Method 3: Tailscale Ingress (HTTP/HTTPS — recommended for web services)

Create a standard Kubernetes `Ingress` with `ingressClassName: tailscale`. The operator provisions an HTTPS-terminating proxy. The service becomes reachable at `https://<hostname>.tailnet.ts.net` with a valid TLS certificate provisioned automatically by Tailscale.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-namespace
  annotations:
    tailscale.com/proxy-class: "prod"
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
  tls:
    - hosts:
        - my-app     # becomes my-app.tailnet.ts.net
```

> **Important — HTTP redirect gotcha:** The Tailscale proxy sends traffic to your backend over plain HTTP (to the port listed in `backend.service.port`). If your backend automatically redirects `http://` → `https://` you will get a redirect loop. Fix this by either:
> - Disabling the internal HTTP→HTTPS redirect in your app (preferred), **or**
> - Pointing the Ingress `port` at the app's HTTPS port and accepting a self-signed cert.

### Method 4: Tailscale Funnel (public internet exposure)

Tailscale Funnel exposes a service to the **public internet** — anyone can reach it, not just tailnet members. Traffic still routes through Tailscale's infrastructure, so there is no need to open firewall ports or configure port-forwarding on your router.

> **Important:** Funnel is only available for HTTPS (port 443). The URL seen by the public is `https://<hostname>.tailnet.ts.net`.

#### Prerequisites

The Tailscale ACL must grant the `funnel` attribute to the `tag:k8s` tag. This is already applied in `opentofu/tailscale.tf`:

```json
"nodeAttrs": [
  {
    "target": ["tag:k8s"],
    "attr":   ["funnel"]
  }
]
```

Without this ACL entry the proxy pod will start but the `tailscale funnel` command will be rejected with a permission error.

#### How to enable Funnel on an Ingress

Add `tailscale.com/funnel: "true"` to the Ingress and reference the `funnel` ProxyClass (defined in `k3s/manifests/tailscale/proxyclass-funnel.yaml`):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-public-app
  namespace: my-namespace
  annotations:
    tailscale.com/proxy-class: "funnel"
    tailscale.com/funnel: "true"
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
  tls:
    - hosts:
        - my-public-app     # becomes my-public-app.tailnet.ts.net (public)
```

#### How to enable Funnel on a Service

Add the same annotation to a LoadBalancer service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-public-service
  namespace: my-namespace
  annotations:
    tailscale.com/hostname: "my-public-service"
    tailscale.com/proxy-class: "funnel"
    tailscale.com/funnel: "true"
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app: my-app
  ports:
    - port: 443
      targetPort: 8080
```

#### Verifying Funnel is active

```bash
# Confirm the proxy pod joined the tailnet and funnel is serving
kubectl logs -n tailscale ts-my-public-app-<hash>-0 | grep -i funnel
# Expected: "funnel: serving on https://my-public-app.tailnet.ts.net"

# Test public access (from any device, even off the tailnet)
curl https://my-public-app.tailnet.ts.net
```

#### Security considerations

- Funnel services are publicly reachable. Always apply authentication/authorization at the application layer.
- Restrict which namespaces or teams can create Funnel-enabled resources using Kubernetes RBAC and/or Tailscale ACL tags.
- Monitor access in the Tailscale admin console under **Machines → \<proxy device\> → Funnel**.

---

## Example: Complete Walkthrough of Adding a New HTTP Service

This walks through exposing a hypothetical app `my-dashboard` running on port `3000`.

### Step 1 — Manifest files

`k3s/manifests/my-dashboard/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-dashboard
  namespace: my-dashboard
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-dashboard
  template:
    metadata:
      labels:
        app: my-dashboard
    spec:
      containers:
        - name: my-dashboard
          image: my-org/my-dashboard:latest
          ports:
            - containerPort: 3000
```

`k3s/manifests/my-dashboard/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-dashboard
  namespace: my-dashboard
spec:
  type: ClusterIP
  selector:
    app: my-dashboard
  ports:
    - port: 3000
      targetPort: 3000
```

`k3s/manifests/my-dashboard/tailscale-ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-dashboard
  namespace: my-dashboard
  annotations:
    tailscale.com/proxy-class: "prod"
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-dashboard
                port:
                  number: 3000
  tls:
    - hosts:
        - my-dashboard
```

### Step 2 — Register with Flux

`k3s/flux/apps/my-dashboard.yaml`:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-dashboard
  namespace: flux-system
spec:
  interval: 10m
  path: ./k3s/manifests/my-dashboard
  prune: true
  sourceRef:
    kind: GitRepository
    name: homelab
  targetNamespace: my-dashboard
```

### Step 3 — Push and verify

```bash
git add k3s/manifests/my-dashboard/ k3s/flux/apps/my-dashboard.yaml
git commit -m "feat: add my-dashboard via Tailscale Ingress"
git push origin main
```

Flux reconciles within ~10 minutes (or run `flux reconcile kustomization my-dashboard -n flux-system`). Then:

```bash
# Watch for the proxy pod to appear
kubectl get pods -n tailscale -w

# Check the Ingress got an address
kubectl get ingress -n my-dashboard
```

Once the proxy is `Running`, the service is available at `https://my-dashboard.tailnet.ts.net`.

---

## Viewing Exposed Services in Tailscale Admin

1. Go to <https://login.tailscale.com/admin/machines>.
2. Filter by tag `tag:k8s` or `tag:k8s-operator` to see only cluster devices.
3. Each proxy appears as a separate device with the hostname you configured.

The operator itself appears as `k3s-tailscale-operator`.

---

## Troubleshooting

### Operator logs

```bash
kubectl logs -n tailscale operator-<hash> --tail=100
```

Common issues:
- `oauth2: cannot fetch token: 401 Unauthorized` / `API token invalid`: OAuth credentials have expired or are wrong. Generate a new OAuth client at <https://login.tailscale.com/admin/settings/oauth> (scopes: `devices:write`, `dns:read`, `dns:write`; tag: `tag:k8s-operator`), apply with `kubectl patch`, then restart the operator — see [Applying credentials to the cluster](#applying-credentials-to-the-cluster). **Note:** existing proxy pods keep running with stale-but-valid auth; only new proxy provisioning fails.
- `failed to authenticate`: OAuth credentials are wrong or not yet applied — re-run the `kubectl patch` command.
- `tag not permitted`: the OAuth client's tag list in Tailscale admin does not include `tag:k8s-operator`.

### Proxy pod logs

```bash
# Find the proxy pod (named ts-<resource>-<hash>-0)
kubectl get pods -n tailscale

kubectl logs -n tailscale ts-my-app-<hash>-0 --tail=100
```

Look for:
- `login complete` — proxy joined the tailnet successfully.
- `Error: tag:k8s not permitted` — the ACL tag ownership is not set up correctly (see [Prerequisites](#prerequisites-tailscale-acl-tags)).

### Proxy pod in `Error` / `NeedsLogin` state

If a proxy pod logs `invalid state: tailscaled daemon started with a config file, but tailscale is not logged in`, its auth key is stale. This happens when the corresponding device was deleted from the Tailscale admin console. Fix it by deleting the auth secret — the operator will provision a fresh key and the pod will restart cleanly:

```bash
kubectl delete secret -n tailscale ts-<resource>-<hash>-0
```

### Proxy hostname has unexpected `-1` (or `-2`) suffix

When a proxy pod restarts, Tailscale will append a `-1` suffix if a device with the intended hostname already exists in the tailnet. To reclaim the clean hostname:

1. Delete the old device from <https://login.tailscale.com/admin/machines> first.
2. Then delete the auth secret so the pod re-authenticates from scratch:

```bash
kubectl delete secret -n tailscale ts-<resource>-<hash>-0
```

The pod will restart and register with the clean hostname. If you delete the pod before the secret, or before the old machine is fully removed from the tailnet, it will race and grab the suffix again.

### Proxy pod is stuck in `Init` state

The init container (`tailscale-init`) authenticates with Tailscale before the main container starts. If it hangs:

```bash
kubectl logs -n tailscale ts-my-app-<hash>-0 -c tailscale-init --tail=50
```

Usually caused by invalid OAuth credentials or network connectivity issues from the node.

### Tag permission errors

If the operator logs show `permission denied` for a tag, verify in the Tailscale ACL that:
1. `tag:k8s-operator` is listed in `tagOwners` (can be empty `[]` for admin-owned).
2. `tag:k8s` is owned by `tag:k8s-operator`.
3. The OAuth client was created with the `tag:k8s-operator` tag selected.

### Service has no Tailscale address after several minutes

```bash
# Check the Ingress or Service for the address field
kubectl describe ingress my-app -n my-namespace
kubectl describe svc my-service -n my-namespace

# Check Flux reconciled the resources
flux get kustomization my-app -n flux-system

# Check operator is running
kubectl get pods -n tailscale -l app=operator
```

If the operator pod is not running, check its logs and ensure the `operator-oauth` secret has real credentials (not `REPLACE_ME`).

---

## Reference

| Item | Value |
|---|---|
| Tailscale admin | <https://login.tailscale.com/admin/machines> |
| Tailnet name | `your-tailnet` |
| Operator hostname | `k3s-tailscale-operator` |
| Operator namespace | `tailscale` |
| OAuth secret name | `operator-oauth` |
| ProxyClass name (tailnet) | `prod` |
| ProxyClass name (Funnel) | `funnel` |
| Helm chart version | `1.94.2` |

**See also:**
- [gitops-flux.md](gitops-flux.md) — how Flux manages these manifests
- [manifests-and-helm.md](manifests-and-helm.md) — full manifest/Helm reference
