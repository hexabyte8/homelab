# Tailscale proxy pod stuck Terminating — service unreachable

## Symptoms

A service exposed via the Tailscale ingress class (e.g. `authentik.tailnet.ts.net`)
becomes completely unreachable from all Tailscale nodes. The DNS name still resolves but
connections time out or are refused.

Checking the `tailscale` namespace shows the proxy pod in a `Completed` or `Terminating`
state with `0/1 Ready` and a non-zero age, while the StatefulSet reports
`availableReplicas: 0`:

```bash
kubectl get pods -n tailscale
# NAME                      READY   STATUS      RESTARTS   AGE
# ts-authentik-abc12-0      0/1     Completed   0          3d8h   ← stuck

kubectl get statefulset ts-authentik-abc12 -n tailscale \
  -o jsonpath='{.status}'
# {"availableReplicas":0, "replicas":1, ...}
```

The pod has a `deletionTimestamp` set, confirming it is stuck in Terminating:

```bash
kubectl get pod ts-authentik-abc12-0 -n tailscale \
  -o jsonpath='{.metadata.deletionTimestamp}'
# 2026-03-22T22:33:16Z  ← set but pod never fully terminated
```

## Root cause

When the k3s API server restarts or becomes temporarily unavailable, in-flight pod
lifecycle operations can be interrupted mid-flight. A Tailscale proxy pod that was in
the process of being terminated gets its `deletionTimestamp` stamped, but the kubelet
never receives (or processes) the final acknowledgement to remove the pod from the API.
The pod is therefore **permanently stuck in Terminating**.

Because a StatefulSet will not create a replacement pod while the previous ordinal pod
still exists in the API (even as a ghost), `availableReplicas` stays at `0` and no new
proxy is scheduled. The Tailscale operator's reconcile loop sees the StatefulSet is
already at `replicas: 1` and does nothing further.

This manifests as the affected service being silently unreachable: the Tailscale MagicDNS
name resolves correctly, but there is no live proxy to forward traffic.

## Identifying the affected pod

```bash
# List all Tailscale proxy pods — look for Completed / 0/1 Ready
kubectl get pods -n tailscale

# Confirm the pod has a stale deletionTimestamp
kubectl get pod <pod-name> -n tailscale \
  -o jsonpath='{.metadata.deletionTimestamp}'

# Cross-check: StatefulSet should show availableReplicas 0
kubectl get statefulset <statefulset-name> -n tailscale \
  -o jsonpath='{.status.availableReplicas}'
```

The StatefulSet name for an ingress resource is shown in the Tailscale operator logs
and follows the pattern `ts-<ingress-name>-<hash>`.

## Fix

Force-delete the stuck pod. The `--force --grace-period=0` flags bypass the normal
graceful termination handshake and remove the object directly from the API:

```bash
kubectl delete pod <pod-name> -n tailscale --force --grace-period=0
```

The StatefulSet controller will immediately schedule a replacement pod. Verify it comes
up healthy:

```bash
kubectl get pods -n tailscale -w
# ts-authentik-abc12-0   1/1   Running   0   15s
```

Check the proxy logs to confirm it connected to Tailscale and applied the serve config:

```bash
kubectl logs <new-pod-name> -n tailscale --tail=20
# ...
# Switching ipn state Starting -> Running (WantRunning=true, nm=true)
# serve proxy: applying serve config
# serve: creating a new proxy handler for http://<cluster-ip>/
```

The service should be reachable within a few seconds of the pod reaching `Running`.

## Verification

```bash
# From any Tailscale node
curl -I https://authentik.tailnet.ts.net
# HTTP/2 200  ← or the expected redirect/login page
```

## Prevention / detection

- The Tailscale operator logs (`kubectl logs -n tailscale deployment/operator`) will
  show `apiserver not ready` errors around the time of the outage, which can be used to
  correlate when pods became stuck.
- Consider adding a liveness or startup probe to the proxy StatefulSet via a
  [`ProxyClass`](https://tailscale.com/kb/1339/kubernetes-operator-api-proxyclass)
  resource so Kubernetes can automatically restart a proxy that stops serving traffic.
- A simple monitoring check against each `*.ts.net` hostname (e.g. via Uptime Kuma) will
  alert on this class of failure before it is noticed manually.

## See also

- [Tailscale Operator docs](https://tailscale.com/kb/1236/kubernetes-operator)
- [Tailscale Operator — `tailscale-operator.md`](../tailscale-operator.md)
