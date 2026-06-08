# Password recovery flow.
#
# Replaces the previous blueprint-based recovery flow (k3s/manifests/authentik/
# blueprints-configmap.yaml). The flow is wired into the default Brand so the
# admin "Send recovery email" action and the "Forgot Password" link on the
# login page both pick it up.
#
# The Email stage uses Authentik's *global* SMTP settings, which are configured
# on the HelmRelease (k3s/flux/apps/authentik.yaml) and point at Stalwart at
# stalwart.stalwart.svc.cluster.local:587 with user noreply (password from
# secret authentik-credentials.smtp-password).

# ---------- Stages ----------

resource "authentik_stage_identification" "recovery" {
  name                      = "default-recovery-identification"
  user_fields               = ["email", "username"]
  pretend_user_exists       = true
  show_matched_user         = true
  case_insensitive_matching = true
}

resource "authentik_stage_email" "recovery" {
  name                     = "default-recovery-email"
  use_global_settings      = true
  token_expiry             = "minutes=30"
  subject                  = "Password Reset - Homelab"
  template                 = "email/password_reset.html"
  activate_user_on_success = true
}

resource "authentik_stage_prompt_field" "recovery_password" {
  name      = "recovery-prompt-password"
  field_key = "password"
  label     = "New Password"
  type      = "password"
  required  = true
  order     = 0
}

resource "authentik_stage_prompt_field" "recovery_password_repeat" {
  name      = "recovery-prompt-password-repeat"
  field_key = "password_repeat"
  label     = "Repeat Password"
  type      = "password"
  required  = true
  order     = 10
}

resource "authentik_stage_prompt" "recovery_password" {
  name = "default-recovery-user-write-prompts"
  fields = [
    authentik_stage_prompt_field.recovery_password.id,
    authentik_stage_prompt_field.recovery_password_repeat.id,
  ]
}

resource "authentik_stage_user_write" "recovery" {
  name               = "default-recovery-user-write"
  user_creation_mode = "never_create"
}

# ---------- Flow ----------

resource "authentik_flow" "recovery" {
  name               = "Default Recovery Flow"
  title              = "Password Recovery"
  slug               = "default-recovery-flow"
  designation        = "recovery"
  authentication     = "none"
  layout             = "stacked"
  denied_action      = "message_continue"
  policy_engine_mode = "any"
}

resource "authentik_flow_stage_binding" "recovery_identification" {
  target               = authentik_flow.recovery.uuid
  stage                = authentik_stage_identification.recovery.id
  order                = 10
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

resource "authentik_flow_stage_binding" "recovery_email" {
  target               = authentik_flow.recovery.uuid
  stage                = authentik_stage_email.recovery.id
  order                = 20
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

resource "authentik_flow_stage_binding" "recovery_password" {
  target               = authentik_flow.recovery.uuid
  stage                = authentik_stage_prompt.recovery_password.id
  order                = 30
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

resource "authentik_flow_stage_binding" "recovery_user_write" {
  target               = authentik_flow.recovery.uuid
  stage                = authentik_stage_user_write.recovery.id
  order                = 40
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

# ---------- Wire the recovery flow into the default Brand ----------
#
# The "Send recovery email" admin action and the "Forgot password" link both
# read brand.flow_recovery, not the flow's designation, so we have to set it
# explicitly. The default brand was created by Authentik on first install; we
# adopt it via an import block.

import {
  to = authentik_brand.default
  id = "7f156b38-dade-4804-953c-d48645e6477d"
}

resource "authentik_brand" "default" {
  domain              = "authentik-default"
  default             = true
  branding_title      = "authentik"
  branding_logo       = "/static/dist/assets/icons/icon_left_brand.svg"
  branding_favicon    = "/static/dist/assets/icons/icon.png"
  flow_authentication = "7aef6921-b280-4f51-9aac-1401f28fee73"
  flow_invalidation   = "dc8654ab-4e21-412e-aafd-ee2e2074906a"
  flow_user_settings  = "eb2f0eb7-6664-4902-9247-cfc66b3c4a63"
  flow_recovery       = authentik_flow.recovery.uuid
}

# ---------- Surface the "Forgot password?" link on the main login page ----------
#
# brand.flow_recovery only handles admin-triggered recovery emails. To get the
# "Forgot password?" link on the standard login page, the identification stage
# of the authentication flow has to point at the recovery flow.

import {
  to = authentik_stage_identification.default_authentication
  id = "ea93d9f5-893e-4f07-9621-2d1ac4fbd15b"
}

resource "authentik_stage_identification" "default_authentication" {
  name                      = "default-authentication-identification"
  user_fields               = ["email", "username"]
  recovery_flow             = authentik_flow.recovery.uuid
  case_insensitive_matching = true
  show_matched_user         = true
  pretend_user_exists       = true
}
