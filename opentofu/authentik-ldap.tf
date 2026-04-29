# LDAP outpost — exposes Authentik users over LDAP for clients that don't
# speak OIDC/SAML (e.g. Jellyfin's LDAP-Auth plugin).
#
# Deployment topology:
#   * authentik_provider_ldap defines the LDAP service (base DN, bind/unbind
#     flows, search behaviour).
#   * authentik_application links it so we can attach policies later if we
#     want to restrict who can bind / be looked up.
#   * authentik_outpost (type = ldap) tells Authentik to *deploy* the outpost
#     pod into the cluster via the local Kubernetes service connection. The
#     resulting Service is `ak-outpost-ldap-outpost.authentik.svc.cluster.local`
#     listening on 389 (LDAP) and 636 (LDAPS, self-signed by default).
#
# Jellyfin LDAP plugin settings:
#   LDAP server:        ak-outpost-ldap-outpost.authentik.svc.cluster.local
#   Port:               389  (or 636 with TLS — outpost generates its own cert)
#   Search base DN:     ou=users,dc=chronobyte,dc=net
#   Search filter:      (&(objectClass=user)(memberOf=cn=family&friends,ou=groups,dc=chronobyte,dc=net))
#   User attr (login):  cn
#   Bind user:          cn=jellyfin-ldap-bind,ou=users,dc=chronobyte,dc=net
#   Bind password:      <set on the authentik_user.jellyfin_ldap_bind resource>

# ---------- Dedicated bind/unbind flows (no MFA stages) ----------
#
# Reusing default-authentication-flow works, but it includes MFA validate /
# device-enrol stages that LDAP clients can't satisfy. A dedicated 2-step
# (identification + password + login) flow keeps Jellyfin's LDAP plugin
# happy and isolates LDAP from MFA churn on the main login flow.

resource "authentik_stage_identification" "ldap_bind" {
  name                      = "ldap-bind-identification"
  user_fields               = ["username", "email"]
  pretend_user_exists       = false
  show_matched_user         = false
  case_insensitive_matching = true
  password_stage            = authentik_stage_password.ldap_bind.id
}

resource "authentik_stage_password" "ldap_bind" {
  name = "ldap-bind-password"
  backends = [
    "authentik.core.auth.InbuiltBackend",
    "authentik.sources.ldap.auth.LDAPBackend",
  ]
  failed_attempts_before_cancel = 5
}

resource "authentik_stage_user_login" "ldap_bind" {
  name             = "ldap-bind-user-login"
  session_duration = "seconds=0"
}

resource "authentik_flow" "ldap_bind" {
  name           = "LDAP Bind"
  title          = "LDAP authentication"
  slug           = "ldap-bind-flow"
  designation    = "authentication"
  authentication = "none"
  layout         = "stacked"
}

resource "authentik_flow_stage_binding" "ldap_bind_identification" {
  target               = authentik_flow.ldap_bind.uuid
  stage                = authentik_stage_identification.ldap_bind.id
  order                = 10
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

resource "authentik_flow_stage_binding" "ldap_bind_user_login" {
  target               = authentik_flow.ldap_bind.uuid
  stage                = authentik_stage_user_login.ldap_bind.id
  order                = 30
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

# ---------- Service account that Jellyfin uses to bind ----------

resource "authentik_user" "jellyfin_ldap_bind" {
  username  = "jellyfin-ldap-bind"
  name      = "Jellyfin LDAP Bind Service Account"
  type      = "service_account"
  is_active = true
  groups    = [authentik_group.family_and_friends.id]
  roles     = [authentik_rbac_role.ldap_searcher.id]
}

# ---------- RBAC: bind user needs `search_full_directory` to enumerate
# users via LDAP. Without this, the LDAP outpost only ever returns the
# bind user themselves (the Go outpost gates the user list on the
# `has_search_permission` field returned by check_access, which is true
# only when the bound user has this permission). The TF provider's
# resource_rbac_permission_user is a no-op, so we wrap the perm in a role
# and assign that role to the bind user. ----------

resource "authentik_rbac_role" "ldap_searcher" {
  name = "ldap-searcher"
}

resource "authentik_rbac_permission_role" "ldap_searcher_search_full_directory" {
  role       = authentik_rbac_role.ldap_searcher.id
  permission = "authentik_providers_ldap.search_full_directory"
  model      = "authentik_providers_ldap.ldapprovider"
  object_id  = tostring(authentik_provider_ldap.main.id)
}

# ---------- LDAP provider + application ----------

resource "authentik_provider_ldap" "main" {
  name             = "ldap"
  base_dn          = "dc=chronobyte,dc=net"
  bind_flow        = authentik_flow.ldap_bind.uuid
  unbind_flow      = data.authentik_flow.default_invalidation.id
  bind_mode        = "cached"
  search_mode      = "direct"
  uid_start_number = 2000
  gid_start_number = 4000
  mfa_support      = false
  tls_server_name  = "ak-outpost-ldap-outpost.authentik.svc.cluster.local"
}

resource "authentik_application" "ldap" {
  name              = "LDAP"
  slug              = "ldap"
  protocol_provider = authentik_provider_ldap.main.id
  meta_description  = "LDAP outpost — exposes Authentik users over LDAP for legacy clients (Jellyfin, etc.)."
}

# Restrict who's visible/bindable via the LDAP outpost to members of
# family&friends. Without any binding, the outpost only exposes the bind
# user itself; with this binding, every family&friends member is searchable.
resource "authentik_policy_binding" "ldap_family_and_friends" {
  target = authentik_application.ldap.uuid
  group  = authentik_group.family_and_friends.id
  order  = 0
}

# (Removed authentik_rbac_permission_user — that resource is a no-op in
# the provider; permission is granted via the ldap_searcher role above.)

# ---------- Outpost (deployed by Authentik via the k8s service connection) ----------
#
# UUID of the "Local Kubernetes Cluster" service connection — there's only
# ever one, and Authentik creates it automatically on install. Looked up via
# GET /api/v3/outposts/service_connections/all/.

locals {
  authentik_k8s_service_connection_id = "f190e0bc-d3c0-4bb7-8ed5-4fc886bd96f6"
}

resource "authentik_outpost" "ldap" {
  name               = "ldap-outpost"
  type               = "ldap"
  service_connection = local.authentik_k8s_service_connection_id
  protocol_providers = [authentik_provider_ldap.main.id]

  # Override the outpost defaults so the deployed pod runs with the same
  # AUTHENTIK_HOST that the embedded outpost reaches (in-cluster, http).
  config = jsonencode({
    authentik_host                 = "http://authentik-server.authentik.svc.cluster.local"
    authentik_host_browser         = "https://authentik.daggertooth-scala.ts.net"
    authentik_host_insecure        = false
    log_level                      = "info"
    object_naming_template         = "ak-outpost-%(name)s"
    docker_network                 = null
    docker_map_ports               = true
    docker_labels                  = null
    container_image                = null
    kubernetes_replicas            = 1
    kubernetes_namespace           = "authentik"
    kubernetes_service_type        = "ClusterIP"
    kubernetes_disabled_components = []
    kubernetes_image_pull_secrets  = []
    kubernetes_ingress_class_name  = null
    kubernetes_ingress_secret_name = ""
    kubernetes_ingress_annotations = {}
    kubernetes_json_patches        = null
  })
}
