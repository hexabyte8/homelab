# Invitation-based enrollment flow.
#
# How it works:
#   1. An admin creates an invitation in the Authentik UI (Directory → Tokens
#      and App passwords → Invitations) bound to the
#      `default-invitation-enrollment` flow.
#   2. The invitation produces a one-time link of the form
#        https://authentik.daggertooth-scala.ts.net/if/flow/default-invitation-enrollment/?itoken=<uuid>
#   3. Recipient opens it, fills in username/name/email/password, and is
#      created as an active user in the family&friends group, then logged in.
#
# The invitation-stage `continue_flow_without_invitation = false` is what
# enforces "you must have an invite to enrol" — bare visits to the flow URL
# without `?itoken=` get a denied screen.

# ---------- Prompts ----------

resource "authentik_stage_prompt_field" "enrol_username" {
  name      = "enrol-prompt-username"
  field_key = "username"
  label     = "Username"
  type      = "username"
  required  = true
  order     = 0
}

resource "authentik_stage_prompt_field" "enrol_name" {
  name      = "enrol-prompt-name"
  field_key = "name"
  label     = "Display Name"
  type      = "text"
  required  = true
  order     = 10
}

resource "authentik_stage_prompt_field" "enrol_email" {
  name      = "enrol-prompt-email"
  field_key = "email"
  label     = "Email"
  type      = "email"
  required  = true
  order     = 20
}

resource "authentik_stage_prompt_field" "enrol_password" {
  name      = "enrol-prompt-password"
  field_key = "password"
  label     = "Password"
  type      = "password"
  required  = true
  order     = 30
}

resource "authentik_stage_prompt_field" "enrol_password_repeat" {
  name      = "enrol-prompt-password-repeat"
  field_key = "password_repeat"
  label     = "Repeat Password"
  type      = "password"
  required  = true
  order     = 40
}

resource "authentik_stage_prompt" "enrolment" {
  name = "default-invitation-enrolment-prompts"
  fields = [
    authentik_stage_prompt_field.enrol_username.id,
    authentik_stage_prompt_field.enrol_name.id,
    authentik_stage_prompt_field.enrol_email.id,
    authentik_stage_prompt_field.enrol_password.id,
    authentik_stage_prompt_field.enrol_password_repeat.id,
  ]
}

# ---------- Stages ----------

resource "authentik_stage_invitation" "enrolment" {
  name                             = "default-invitation-stage"
  continue_flow_without_invitation = false
}

resource "authentik_stage_user_write" "enrolment" {
  name                     = "default-invitation-user-write"
  user_creation_mode       = "always_create"
  create_users_as_inactive = false
  user_type                = "internal"
  create_users_group       = authentik_group.family_and_friends.id
  user_path_template       = "users/family-friends"
}

resource "authentik_stage_user_login" "enrolment" {
  name             = "default-invitation-user-login"
  session_duration = "hours=24"
}

# ---------- Flow ----------

resource "authentik_flow" "enrolment" {
  name           = "Family & Friends Enrolment"
  title          = "Welcome to the Homelab"
  slug           = "default-invitation-enrollment"
  designation    = "enrollment"
  authentication = "none"
  layout         = "stacked"
  denied_action  = "message_continue"
}

resource "authentik_flow_stage_binding" "enrolment_invitation" {
  target               = authentik_flow.enrolment.uuid
  stage                = authentik_stage_invitation.enrolment.id
  order                = 10
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

resource "authentik_flow_stage_binding" "enrolment_prompt" {
  target               = authentik_flow.enrolment.uuid
  stage                = authentik_stage_prompt.enrolment.id
  order                = 20
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

resource "authentik_flow_stage_binding" "enrolment_user_write" {
  target               = authentik_flow.enrolment.uuid
  stage                = authentik_stage_user_write.enrolment.id
  order                = 30
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

resource "authentik_flow_stage_binding" "enrolment_user_login" {
  target               = authentik_flow.enrolment.uuid
  stage                = authentik_stage_user_login.enrolment.id
  order                = 40
  evaluate_on_plan     = true
  re_evaluate_policies = false
}
