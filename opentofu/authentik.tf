# Authentik — managed via the goauthentik/authentik OpenTofu provider.
#
# This file owns the provider, shared lookups, the embedded outpost adoption,
# the "family&friends" group, and the proxy providers/applications for the
# public ForwardAuth-protected services. Recovery flow lives in
# authentik-recovery.tf, invitation-based enrollment in authentik-enrollment.tf,
# and the LDAP outpost in authentik-ldap.tf.
#
# Adding a new ForwardAuth-protected app:
#   1. Add an authentik_provider_proxy resource (mode = "forward_single").
#   2. Add an authentik_application that references it.
#   3. Append the new provider's id to authentik_outpost.embedded.protocol_providers.
#   4. Make sure the corresponding Cloudflare Tunnel ingress + DNS record exist
#      and the Kubernetes Ingress chains the
#        kube-system-cloudflare-https-scheme@kubernetescrd,authentik-authentik-forward-auth@kubernetescrd
#      middlewares (in that order).

# ---------- Lookups ----------

data "authentik_flow" "default_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_invalidation" {
  slug = "default-provider-invalidation-flow"
}

# ---------- Groups ----------

resource "authentik_group" "family_and_friends" {
  name         = "family&friends"
  is_superuser = false
}

# ---------- Proxy providers (one per ForwardAuth-protected app) ----------
#
# NOTE: Jellyfin is intentionally NOT behind ForwardAuth. Native Jellyfin
# clients (TVs, mobile apps, etc.) can't complete a browser SSO round-trip,
# so jellyfin.domain.net serves Jellyfin's own login page and uses the
# Authentik LDAP outpost for authentication (see opentofu/authentik-ldap.tf).

resource "authentik_provider_proxy" "dashy" {
  name               = "dashy"
  mode               = "forward_single"
  external_host      = "https://dashy.${var.cloudflare_zone_name}"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
}

# ---------- Applications ----------

resource "authentik_application" "dashy" {
  name              = "Homelab Dashboard"
  slug              = "dashy"
  protocol_provider = authentik_provider_proxy.dashy.id
  meta_launch_url   = "https://dashy.${var.cloudflare_zone_name}"
  meta_description  = "Homelab service dashboard (public, ForwardAuth-protected)."
  open_in_new_tab   = false
}

# ---------- Policy bindings ----------
#
# Explicit group bindings restrict which groups can access each application.
# dashy: no bindings → any authenticated user (admins only in practice)
#
# family&friends is currently scoped to Jellyfin (LDAP binding in authentik-ldap.tf).

# ---------- Embedded outpost ----------
#
# Adopted via `import` block so the existing instance is managed in place.
# UUID was looked up via the API: GET /api/v3/outposts/instances/?name=...

import {
  to = authentik_outpost.embedded
  id = "483881ad-9e3f-4bff-8c0b-96ba76a04184"
}

resource "authentik_outpost" "embedded" {
  name = "authentik Embedded Outpost"
  type = "proxy"
  protocol_providers = [
    authentik_provider_proxy.dashy.id,
  ]
}
