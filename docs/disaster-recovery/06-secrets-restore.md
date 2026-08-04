# Phase 6: Secrets Restore

> **Time estimate:** ~20–25 minutes
>
> **What this does:** Applies credentials that cannot be stored in the GitHub repository
> (because they are secrets) and must be manually injected after Flux bootstrap.

---

## Why Are Secrets Handled Separately?

Flux syncs everything from the GitHub repository to the cluster. However, real secrets
(API keys, OAuth credentials) cannot be stored in a public or even private git repository
without risk. If the repository is ever compromised or accidentally made public, those
credentials would be exposed.

The solution: store **placeholder values** in git, annotate the Secret with
`kustomize.toolkit.fluxcd.io/reconcile: disabled`, and replace them with real values
manually after each deployment. Flux will skip reconciling annotated secrets and will
not overwrite them.

## Secrets Quick Reference

Cluster secrets are now managed in two ways:

**Automatic (sm-operator):** Most secrets sync directly from BWS into k8s Secrets
via `BitwardenSecret` CRDs. Once the `bw-auth-token` bootstrap token is in place,
the operator handles everything automatically.

**Manual (k3s-patch-secrets workflow):** A small set of non-Flux-managed secrets
(chatto, minecraft, mcp-proxmox) and the ClusterIssuer email still require the workflow.

| # | What to do | How |
|---|------------|-----|
| 1 | Bootstrap `bw-auth-token` in all operator namespaces | Run `k3s-patch-secrets` → target: `bw-auth-token` |
| 2 | All operator-managed secrets (authentik, cert-manager, cloudflared, grafana, stalwart, tailscale, actual, transmission) | Automatic — sm-operator syncs from BWS within 5 minutes |
| 3 | chatto, minecraft, mcp-proxmox secrets | Run `k3s-patch-secrets` → target: `all` |
| 4 | cert-manager letsencrypt email | Run `k3s-patch-secrets` → target: `cert-manager-letsencrypt-email` |

---

## 6.1 Bootstrap bw-auth-token

The `sm-operator` needs a BWS Machine Account Access Token in each namespace where
it manages secrets. This is the only thing you need to seed manually.

**Prerequisites (already configured — only relevant if rebuilding from scratch):**
1. BWS Machine Account exists with Read+Write access to the homelab project
2. Access Token stored as BWS secret `68a5f06c-2b1f-4308-ba6b-b49b01722993` (`BWS-OPS-TOKEN`)
3. GitHub secret `BW_ACCESS_TOKEN` contains the machine account access token
4. Org ID `5f82d531-e61f-4c86-963c-b40f00c51c93` and Project ID `aece2880-f0d0-4a77-9b0c-b40f00c78f1e`
   are already set in all `k3s/manifests/*/bw-secret.yaml` files

**Run the workflow:**
```
Actions → k3s - Patch Cluster Secrets → Run workflow
target: bw-auth-token
```

The sm-operator will begin syncing all secrets within 5 minutes. No further steps needed
for the operator-managed secrets.

**Verify the operator is working:**
```bash
kubectl get bitwardensecret -A
# All should show condition Ready/Available

kubectl get secret authentik-credentials -n authentik -o jsonpath='{.data}' | jq 'keys'
# Should show ["bootstrap-email","bootstrap-password","secret-key","smtp-password"]
```

---

## 6.2 Non-operator secrets + ClusterIssuer

```
Actions → k3s - Patch Cluster Secrets → Run workflow
target: all
```

This patches chatto-config, minecraft-secrets, mcp-proxmox-secrets, and the
letsencrypt-production ClusterIssuer email.

---

## 6.3 Post-Restore: Authentik OpenTofu Configuration

All Authentik configuration (flows, providers, applications, outposts, LDAP) is managed
by **OpenTofu** in `opentofu/authentik/`. After a fresh restore, run `tofu apply` via
GitHub Actions to re-provision all Authentik resources (including the Grafana and Actual
OAuth2 providers whose secrets will be automatically written to BWS by the workflow):

```
Actions → OpenTofu Apply → Run workflow
```

**Verify the recovery flow exists** (critical for password reset):
```bash
kubectl exec -n authentik deployment/authentik-server -- \
  ak shell -c "from authentik.flows.models import Flow; print(list(Flow.objects.filter(slug='default-recovery-flow').values('slug','name')))"
```

---

## 6.4 Deploy Game Server Services (Optional)

```bash
# Via GitHub Actions:
# Actions → Ansible - Deploy S3 Backup → target_host: game-server
# Actions → Ansible - Deploy Minecraft → target_host: game-server
```

---

## Summary Checklist

Before proceeding to Phase 7:

- [ ] `bw-auth-token` bootstrapped in all operator namespaces (`k3s-patch-secrets` → `bw-auth-token`)
- [ ] sm-operator pods running in `sm-operator-system` namespace
- [ ] `kubectl get bitwardensecret -A` — all show Ready
- [ ] Authentik accessible at `https://authentik.<tailnet>`
- [ ] OpenTofu Apply completed — Authentik flows and OAuth providers provisioned
- [ ] Non-operator secrets patched (`k3s-patch-secrets` → `all`)
- [ ] (Optional) Game server services restored
