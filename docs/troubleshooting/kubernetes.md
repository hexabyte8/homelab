# Kubernetes General troubleshooting and debugging tools

This is just documentation with some useful tools and notes about Kubernetes debugging.

## Debugging pods and containers

- To get a shell in a temporary pod

```bash
kubectl run -i --tty --rm debug-pod --image=busybox --restart=Never -- sh
```

- To get a shell in an existing pod

```bash
kubectl exec -it <pod-name> -- sh
```

- To get logs from a pod

```bash
kubectl logs <pod-name>
```

- To get logs from a specific container in a pod

```bash
kubectl logs <pod-name> -c <container-name>
```

- To get logs from a pod and follow them in real-time

```bash
kubectl logs -f <pod-name>
```

- To get logs from a specific container in a pod and follow them in real-time

```bash
kubectl logs -f <pod-name> -c <container-name>
```

- To describe a pod and get detailed information about it

```bash
kubectl describe pod <pod-name>
```

- To get the events related to a pod

```bash
kubectl get events --field-selector involvedObject.name=<pod-name>
```

- To get the status of a pod

```bash
kubectl get pod <pod-name> -o wide
```

- To get the resource usage of a pod

```bash
kubectl top pod <pod-name>
```

- To get the resource usage of all pods

```bash
kubectl top pods
```

- To get the resource usage of a specific container in a pod

```bash
kubectl top pod <pod-name> -c <container-name>
```
