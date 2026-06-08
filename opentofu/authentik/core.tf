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

# Scope mappings for OIDC providers (openid + email + profile)
data "authentik_property_mapping_provider_scope" "oidc_standard" {
  managed_list = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
  ]
}

# Default self-signed cert used as signing key for OIDC tokens
data "authentik_certificate_key_pair" "default" {
  name = "authentik Self-signed Certificate"
}

# ---------- Groups ----------

resource "authentik_group" "family_and_friends" {
  name         = "family&friends"
  is_superuser = false
}

# ---------- Proxy providers (one per ForwardAuth-protected app) ----------

resource "authentik_provider_proxy" "dashy" {
  name               = "dashy"
  mode               = "forward_single"
  external_host      = "https://dashy.${var.cloudflare_zone_name}"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
}

resource "authentik_provider_proxy" "calibre" {
  name               = "calibre"
  mode               = "forward_single"
  external_host      = "https://calibre.${var.cloudflare_zone_name}"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
}

resource "authentik_provider_proxy" "uptime_kuma" {
  name               = "uptime-kuma"
  mode               = "forward_single"
  external_host      = "https://uptime-kuma.${var.cloudflare_zone_name}"
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

resource "authentik_application" "calibre" {
  name              = "Calibre Web"
  slug              = "calibre"
  protocol_provider = authentik_provider_proxy.calibre.id
  meta_launch_url   = "https://calibre.${var.cloudflare_zone_name}"
  meta_description  = "Calibre Web eBook server (public, ForwardAuth-protected)."
  open_in_new_tab   = false
}

resource "authentik_application" "uptime_kuma" {
  name              = "Uptime Kuma"
  slug              = "uptime-kuma"
  protocol_provider = authentik_provider_proxy.uptime_kuma.id
  meta_launch_url   = "https://uptime-kuma.${var.cloudflare_zone_name}"
  meta_description  = "Uptime Kuma monitoring dashboard (public, ForwardAuth-protected)."
  open_in_new_tab   = false
}


# ---------- Policy bindings ----------
#
# Explicit group bindings restrict which groups can access each application.

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
    authentik_provider_proxy.calibre.id,
    authentik_provider_proxy.uptime_kuma.id,
  ]
  config = jsonencode({
    authentik_host          = "https://authentik.${var.cloudflare_zone_name}"
    authentik_host_insecure = false
  })
}

# ---------- OAuth2/OIDC provider — Grafana (Tailscale-only) ----------
#
# Grafana uses the generic OAuth2 provider to authenticate against Authentik.
# The client_id is deterministic ("grafana"); the client_secret is auto-generated
# and exposed via the sensitive output below. Patch it into the cluster secret:
#
#   kubectl patch secret grafana-oauth-secret -n monitoring --type=merge \
#     -p '{"stringData":{"GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"grafana",
#           "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET":"<tofu output -raw grafana_oauth2_client_secret>"}}'

resource "authentik_provider_oauth2" "grafana" {
  name               = "Grafana"
  client_id          = "grafana"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc_standard.ids
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://grafana.daggertooth-scala.ts.net/login/generic_oauth"
    }
  ]
  sub_mode                    = "hashed_user_id"
  include_claims_in_id_token  = true
  access_token_validity       = "hours=1"
  refresh_token_validity      = "days=30"
}

resource "authentik_application" "grafana" {
  name              = "Grafana"
  slug              = "grafana"
  protocol_provider = authentik_provider_oauth2.grafana.id
  meta_launch_url   = "https://grafana.daggertooth-scala.ts.net"
  meta_description  = "Grafana monitoring dashboard (Tailscale-only, SSO via Authentik OIDC)."
  open_in_new_tab   = false
}

# ---------- Outputs ----------

output "grafana_oauth2_client_id" {
  description = "Authentik OAuth2 client_id for Grafana."
  value       = authentik_provider_oauth2.grafana.client_id
}

output "grafana_oauth2_client_secret" {
  description = "Authentik OAuth2 client_secret for Grafana. Use to patch grafana-oauth-secret in the monitoring namespace."
  value       = authentik_provider_oauth2.grafana.client_secret
  sensitive   = true
}
