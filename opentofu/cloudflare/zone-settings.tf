# Zone-level security settings for the Cloudflare zone.
#
# Clears the Cloudflare Security Insights findings reported for the
# tunnel-proxied hostnames:
#   - "Domains without 'Always Use HTTPS'"   -> always_use_https = on
#   - "Domains supporting older TLS version" -> min_tls_version  = 1.2
#   - "Domains without HSTS"                 -> security_header (HSTS) below
#
# These settings are enforced at the Cloudflare edge and therefore only apply
# to proxied (orange-clouded) hostnames. DNS-only records bypass the edge:
#   - docs.<zone> (GitHub Pages) already enforces HTTPS with its own
#     Let's Encrypt cert, but it cannot receive an HSTS header from us:
#     proxying it would break GitHub's certificate provisioning (see the
#     docs record in tunnel.tf). Its "Domains without HSTS" insight is an
#     accepted residual finding.
#   - game.<zone> / zomb.<zone> are raw UDP game servers (no HTTP at all).
#   - send.<zone> (MX/TXT) and the other TXT/MX records are non-HTTP.

# 301-redirect every plain-HTTP request on proxied hostnames to HTTPS.
resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# Reject TLS < 1.2 on proxied hostnames. Every browser-facing service here is
# reached by modern clients, so nothing legitimately needs 1.0/1.1.
resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

# HSTS via the zone security header (Strict-Transport-Security), plus
# X-Content-Type-Options: nosniff on proxied responses.
#
# include_subdomains is safe for this zone: every browser-facing subdomain
# serves HTTPS (proxied hostnames via Cloudflare edge certificates; the
# DNS-only ones are either HTTPS-only or non-HTTP). Any *future* subdomain
# must be HTTPS-ready from day one or browsers will refuse plain HTTP for it
# for the duration of max_age below.
#
# preload stays off — submitting to the HSTS preload list is effectively
# irreversible and unnecessary for a homelab. max_age is 6 months: long
# enough to be meaningful, short enough that a mistake self-heals.
resource "cloudflare_zone_setting" "security_header" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      include_subdomains = true
      max_age            = 15552000 # 180 days
      nosniff            = true
      preload            = false
    }
  }
}