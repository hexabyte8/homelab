# Cloudflare Email Routing for chronobyte.net
#
# Enables email routing so that emails sent to @chronobyte.net addresses
# are handled by Cloudflare rather than requiring a port 25 inbound listener.
#
# Cloudflare automatically manages MX records when email routing is enabled.
# The catch-all rule below forwards all @chronobyte.net mail to the admin email.
#
# IMPORTANT: After running `tofu apply`, Cloudflare will send a verification
# email to var.admin_email. You must click the link to activate forwarding.

resource "cloudflare_email_routing_settings" "chronobyte" {
  zone_id = var.cloudflare_zone_id
}

# Verified destination address — Cloudflare sends a one-time verification link.
resource "cloudflare_email_routing_address" "admin" {
  account_id = var.cloudflare_account_id
  email      = var.admin_email
}

# Forward all @chronobyte.net mail to the admin email address.
# Once Stalwart is fully deployed and its JMAP endpoint is accessible at
# https://mail.chronobyte.net, this can be replaced with a Cloudflare Email
# Worker that delivers directly to Stalwart via the JMAP API.
resource "cloudflare_email_routing_catch_all" "forward_to_admin" {
  zone_id = var.cloudflare_zone_id
  name    = "Forward all to admin"
  enabled = true

  matchers = [{
    type = "all"
  }]

  actions = [{
    type  = "forward"
    value = [cloudflare_email_routing_address.admin.email]
  }]

  depends_on = [cloudflare_email_routing_settings.chronobyte]
}
