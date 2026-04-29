# Non-root container can't write to Longhorn PVC / probes fail behind proxy

Two issues that frequently appear together when deploying non-root containers with
persistent storage:

1. **PVC permission denied** — the container user can't write to a mounted volume
2. **Liveness/readiness probes failing** — the app binds to `127.0.0.1` instead of `0.0.0.0`

## Symptoms

### Issue 1 — PermissionError on PVC

The pod enters a crash loop immediately after startup:

```bash
kubectl get pods -n <namespace>
# NAME                        READY   STATUS             RESTARTS   AGE
# myapp-6d9f7b8c4-xk2pq       0/1     CrashLoopBackOff   5          3m
```

Pod logs show a permission error when the app tries to write to a mounted volume:

```bash
kubectl logs -n <namespace> <pod-name>
# PermissionError: [Errno 13] Permission denied: '<mount-path>/somefile'
```

Pod events confirm the container is starting successfully — it's the application
itself that's failing:

```bash
kubectl describe pod -n <namespace> <pod-name>
# Normal   Started    ...  Started container myapp
# Warning  BackOff    ...  Back-off restarting failed container myapp
```

### Issue 2 — Probe failures after a `BEHIND_PROXY` / trusted-proxy flag

After fixing the PVC issue the pod still crash-loops. Events show probe failures:

```bash
kubectl describe pod -n <namespace> <pod-name>
# Warning  Unhealthy  ...  Liveness probe failed:  dial tcp <pod-ip>:5000: connect: connection refused
# Warning  Unhealthy  ...  Readiness probe failed: dial tcp <pod-ip>:5000: connect: connection refused
# Normal   Killing    ...  Container myapp failed liveness probe, will be restarted
```

The app logs show it started successfully and is listening — but only on localhost:

```bash
kubectl logs -n <namespace> <pod-name>
# Running on http://127.0.0.1:5000
```

## Root cause

### Issue 1 — Volume ownership

Longhorn (and most Kubernetes storage provisioners) create new volumes owned by
`root:root` with mode `755`. A non-root container user has no write permission
on these directories by default.

To confirm the container user's UID/GID:

```bash
kubectl run --rm -it uid-check --image=<image> --restart=Never --command -- id
# uid=999(appuser) gid=999(appuser) groups=999(appuser)
```

Without a `securityContext.fsGroup` on the pod, the mounted volume remains
root-owned and the non-root process gets `EACCES (Permission denied)`.

### Issue 2 — Localhost-only bind when behind-proxy mode is active

Some applications (e.g. Flask with `BEHIND_PROXY=true`, or any framework that
enables a trusted-proxy / forwarded-headers mode) default to binding on
`127.0.0.1` rather than `0.0.0.0` when reverse-proxy mode is enabled. The
reasoning is that the app should only be reachable through the proxy.

Inside a Kubernetes pod, **kubelet probes connect to the pod's IP address**, not
to `127.0.0.1`. A process listening only on `127.0.0.1` is unreachable from the
kubelet, so all `httpGet` probes fail with `connection refused`. After the
liveness probe grace period expires, the kubelet kills the container, and the
pod enters `CrashLoopBackOff`.

## Fix

### Issue 1 — Add `fsGroup` to the pod security context

Kubernetes sets the GID ownership of every mounted volume to `fsGroup` at pod
start-up, and sets the setgid bit so new files inherit the group. Set `fsGroup`
to the GID the container runs as:

```yaml
spec:
  securityContext:
    fsGroup: <gid>   # e.g. 999
  containers:
    - name: myapp
      ...
```

Full minimal example:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: myapp
spec:
  template:
    spec:
      securityContext:
        fsGroup: 999
      containers:
        - name: myapp
          image: example/myapp:latest
          volumeMounts:
            - name: data
              mountPath: /app/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: myapp-data
```

After applying, verify the mount is writable:

```bash
kubectl exec -n <namespace> <pod-name> -- ls -la <mount-path>
# drwxrwsr-x 2 root 999 4096 ...   ← group 999, setgid bit set
```

### Issue 2 — Override the bind address via environment variable

Add an environment variable that forces the application to listen on all
interfaces. The exact variable name depends on the application; common patterns:

```yaml
containers:
  - name: myapp
    env:
      - name: APP_HOST        # Flask / Gunicorn style
        value: "0.0.0.0"
      - name: APP_BIND        # alternative name used by some apps
        value: "0.0.0.0"
```

Check the application's documentation or source for the correct variable. After
adding it, confirm the app binds on `0.0.0.0`:

```bash
kubectl logs -n <namespace> <pod-name>
# Running on http://0.0.0.0:5000   ✓
```

### Both fixes together

A deployment snippet with both fixes applied:

```yaml
spec:
  template:
    spec:
      securityContext:
        fsGroup: 999
      containers:
        - name: myapp
          image: example/myapp:latest
          env:
            - name: APP_HOST
              value: "0.0.0.0"
          livenessProbe:
            httpGet:
              path: /health
              port: 5000
          readinessProbe:
            httpGet:
              path: /health
              port: 5000
          volumeMounts:
            - name: config
              mountPath: /app/config
            - name: logs
              mountPath: /app/logs
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: myapp-config
        - name: logs
          persistentVolumeClaim:
            claimName: myapp-logs
```

## Prevention

When adding any service that runs as a non-root user:

1. **Check the container UID/GID before writing the manifest.** Run the image
   locally or use a one-shot pod:

   ```bash
   kubectl run --rm -it uid-check --image=<image> --restart=Never --command -- id
   # uid=999(appuser) gid=999(appuser) groups=999(appuser)
   ```

2. **Always set `securityContext.fsGroup`** on the pod spec whenever the
   container mounts a PVC and runs as a non-root user.

3. **Check how the application selects its bind address.** If the app has a
   behind-proxy / trusted-proxy / forwarded-headers mode, verify it still binds
   on `0.0.0.0` and not `127.0.0.1`. Add an explicit `HOST`/`BIND` env var to
   be safe.

4. **Ensure liveness/readiness probes target a reachable address.** Kubelet
   probes connect to the pod IP, not `localhost`. Use `httpGet` with the
   container's service port; never rely on localhost-only listeners passing
   probes.

## See also

- [New Service Guide](../new-service.md)
- [Longhorn storage](https://longhorn.io/docs/latest/volumes-and-nodes/volume-owner-and-group/)
- [Kubernetes — Configure a Security Context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-pod)
- [Kubernetes — Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
