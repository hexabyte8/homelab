# AdGuard Home web UI port set to 443 — pod crash loop

## Symptoms

The AdGuard Home pod enters a crash loop shortly after first-run setup, cycling
through `Running → Error → CrashLoopBackOff` with a rapidly increasing restart count:

```bash
kubectl get pods -n adguard
# NAME                           READY   STATUS             RESTARTS   AGE
# adguard-home-7bbd7b85f8-vlhw6  0/1     CrashLoopBackOff   38         2h
```

Pod events show the liveness and readiness probes repeatedly failing on port 3000:

```bash
kubectl describe pod -n adguard -l app=adguard-home
# Warning  Unhealthy  ...  Readiness probe failed: dial tcp <pod-ip>:3000: connection refused
# Warning  Unhealthy  ...  Liveness probe failed:  dial tcp <pod-ip>:3000: connection refused
# Normal   Killing    ...  Container adguard-home failed liveness probe, will be restarted
```

The Tailscale proxy for the web UI also logs connection refused errors:

```bash
kubectl logs -n tailscale <ts-adguard-home-...> | grep "proxy error"
# http: proxy error: dial tcp 10.43.x.x:3000: connect: connection refused
```

## Root cause

The AdGuard Home first-run setup wizard asks for an **Admin Web Interface** port.
If this is changed from the default `3000` to `443`, AdGuard binds its web UI to
port 443 instead of 3000. The Kubernetes liveness and readiness probes are hardcoded
to check `http://<pod-ip>:3000/` — they fail immediately, and the kubelet kills and
restarts the container in a loop.

The pod logs confirm AdGuard is running but on the wrong port:

```
[info] go to http://10.42.x.x:443
[info] starting plain server addr=0.0.0.0:443
```

Note: changing the web UI port to 443 is unnecessary in this setup. The Tailscale
Ingress terminates HTTPS externally and proxies to `http://<cluster-ip>:3000`
internally. AdGuard never needs to serve TLS itself.

## Fix

### 1. Suspend Flux reconciliation temporarily

Flux will keep reconciling the deployment during the repair. Suspend the kustomization:

```bash
flux suspend kustomization adguard -n flux-system
```

### 2. Scale the deployment to zero

```bash
kubectl scale deployment adguard-home -n adguard --replicas=0
# Wait for all pods to terminate
kubectl wait --for=delete pod -l app=adguard-home -n adguard --timeout=60s
```

### 3. Spin up a debug pod to edit the config

The config is stored on the `adguard-conf` Longhorn PVC at
`/opt/adguardhome/conf/AdGuardHome.yaml`.

```bash
kubectl run adguard-fix -n adguard --restart=Never \
  --image=busybox \
  --overrides='{
    "spec": {
      "volumes": [{"name":"conf","persistentVolumeClaim":{"claimName":"adguard-conf"}}],
      "containers": [{
        "name": "fix",
        "image": "busybox",
        "command": ["sh","-c","sleep 600"],
        "volumeMounts": [{"mountPath":"/conf","name":"conf"}]
      }]
    }
  }'

# Wait for it to start
kubectl wait pod adguard-fix -n adguard --for=condition=Ready --timeout=60s
```

### 4. Patch the port in the config file

```bash
kubectl exec adguard-fix -n adguard -- \
  sed -i 's/address: 0.0.0.0:443/address: 0.0.0.0:3000/' /conf/AdGuardHome.yaml

# Verify
kubectl exec adguard-fix -n adguard -- grep 'address:' /conf/AdGuardHome.yaml
# address: 0.0.0.0:3000  ✓
```

### 5. Clean up and restore

```bash
# Remove the debug pod
kubectl delete pod adguard-fix -n adguard

# Resume Flux reconciliation (Flux will scale the deployment back to 1)
flux resume kustomization adguard -n flux-system
```

### 6. Verify

```bash
kubectl get pods -n adguard -w
# adguard-home-...-xxxxx   0/1   ContainerCreating   0   5s
# adguard-home-...-xxxxx   1/1   Running             0   30s  ✓

kubectl logs -n adguard -l app=adguard-home | grep "go to http"
# [info] go to http://10.42.x.x:3000  ✓
```

The web UI should be reachable at `https://adguard.tailnet.ts.net` within
a few seconds of the pod reaching `Running`.

## Prevention

During the AdGuard setup wizard, **leave the Admin Web Interface port at `3000`**.
The Tailscale Ingress handles HTTPS on port 443 externally. See the
[first-run setup guide](../adguard.md#first-run-setup) for the full list of recommended
wizard settings.

## See also

- [AdGuard Home — First-Run Setup](../adguard.md#first-run-setup)
- [Tailscale Operator](../tailscale-operator.md)
