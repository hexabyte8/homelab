# Homelab Topology

This page provides a complete visual overview of the homelab infrastructure — from physical hardware to running services and how everything connects.

---

## Traffic Flow: Public Request (Cloudflare Tunnel)

```mermaid
sequenceDiagram
    participant User as 🌐 User (Internet)
    participant CF as Cloudflare Edge
    participant CFD as cloudflared pods
    participant Traefik as Traefik (kube-system)
    participant Auth as Authentik (ForwardAuth)
    participant App as Application Pod

    User->>CF: HTTPS request to *.example.com
    CF->>CFD: Outbound tunnel (HTTP/2)
    CFD->>Traefik: Forward request (HTTP)
    Traefik->>Traefik: Rewrite X-Forwarded-Proto: https
    Traefik->>Auth: ForwardAuth check
    Auth-->>Traefik: 200 OK (authenticated)
    Traefik->>App: Proxy to application
    App-->>Traefik: Response
    Traefik-->>CFD: Response
    CFD-->>CF: Response via tunnel
    CF-->>User: HTTPS response
```

---

## Traffic Flow: Private Request (Tailscale)

```mermaid
sequenceDiagram
    participant User as 👤 Tailnet Member
    participant TS as Tailscale Network
    participant TSProxy as Tailscale Proxy Pod
    participant App as Application Pod

    User->>TS: HTTPS request to *.tailnet.ts.net
    TS->>TSProxy: Route via WireGuard tunnel
    TSProxy->>App: Proxy to application (TLS terminated by Tailscale)
    App-->>TSProxy: Response
    TSProxy-->>TS: Response
    TS-->>User: HTTPS response
```

---

## GitOps Sync Flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub (main)
    participant Flux as Flux CD (flux-system)
    participant K8s as Kubernetes Cluster

    Dev->>GH: git push main
    GH-->>Flux: Change detected (poll ~1 min)
    Flux->>K8s: Apply changed manifests (SSA)
    K8s-->>Flux: Reconcile complete
    Note over Flux,K8s: Continuous drift detection:<br/>Flux reverts any manual cluster changes
```

---

## Storage Architecture

```mermaid
graph TD
    subgraph k3s_nodes["k3s Worker Nodes"]
        subgraph node1["k3s-agent-1"]
            disk1["Local disk<br/>(Longhorn replica)"]
        end
        subgraph node2["k3s-agent-2"]
            disk2["Local disk<br/>(Longhorn replica)"]
        end
    end

    pvc["PersistentVolumeClaim (PVC)"] --> lh["Longhorn Volume<br/>(2 replicas)"]
    lh --> disk1
    lh --> disk2

    lh -->|"scheduled snapshots"| s3["AWS S3<br/>(backup destination)"]

    subgraph apps_with_pvc["Applications with Persistent Storage"]
        authentik_db["Authentik PostgreSQL (CNPG)"]
        grafana_pvc["Grafana (1 Gi)"]
        prom_pvc["Prometheus (20 Gi)"]
        jellyfin_pvc["Jellyfin media library"]
        longhorn_ui_pvc["Longhorn UI"]
        stalwart_pvc["Stalwart Mail"]
    end

    apps_with_pvc --> pvc
```

---

## Network Zones

```mermaid
graph LR
    subgraph public["Public Internet"]
        user["External User"]
    end

    subgraph cloudflare_zone["Cloudflare Zone (example.com)"]
        dns["DNS records"]
        tunnel["Cloudflare Tunnel"]
    end

    subgraph tailnet_zone["Tailnet (tailnet.ts.net)"]
        admin["Admin / Developer<br/>(tailnet member)"]
        ts_mesh["WireGuard mesh"]
    end

    subgraph lan["LAN (<lan-cidr>)"]
        proxmox_host["Proxmox host<br/><proxmox-lan-ip>"]
        vm_net["VMs<br/><k3s-agent-1-lan-ip>–<k3s-agent-2-lan-ip>"]
    end

    subgraph cluster_net["Cluster Network"]
        pod_cidr["Pod CIDR: 10.42.0.0/16<br/>(Flannel CNI; VTEP endpoints use<br/>Tailscale IPs for cross-node routing)"]
        svc_cidr["Service CIDR: 10.43.0.0/16"]
    end

    user --> dns --> tunnel --> vm_net
    admin --> ts_mesh --> vm_net
    vm_net --> cluster_net
    proxmox_host --> vm_net
```
