# Cloudflare Tunnel — ingress routing and DNS records.
#
# The tunnel was created via the Cloudflare dashboard. Import it into state with:
# (The <tunnel_id> can be retrieved from the Cloudflare dashboard or from
#   tofu import cloudflare_zero_trust_tunnel_cloudflared.homelab \
#     <account_id>/<tunnel_id>
#
# Then import the config resource:
#   tofu import cloudflare_zero_trust_tunnel_cloudflared_config.homelab \
#     <account_id>/<tunnel_id>
#
# Adding a new public service:
#   1. Add an ingress entry before the catch-all below
#   2. Add a cloudflare_dns_record resource
#   3. Add a Traefik Ingress in k3s/manifests/<app>/ingress-cloudflare.yaml

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id = var.cloudflare_account_id
  name       = "homelab"
  config_src = "cloudflare"
}

# Ingress routing — order matters, first match wins, catch-all must be last.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id

  config = {
    ingress = [
      {
        hostname = "uptime.${var.cloudflare_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      {
        hostname = "mail.${var.cloudflare_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      {
        hostname = "calibre.${var.cloudflare_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      {
        hostname = "jellyfin.${var.cloudflare_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      {
        hostname = "dashy.${var.cloudflare_zone_name}"
        service  = "http://traefik.kube-system.svc.cluster.local:80"
      },
      # Catch-all: reject unmatched hostnames
      {
        service = "http_status:404"
      }
    ]
  }
}

# DNS — CNAME each public hostname to the tunnel endpoint.
# proxied = true hides the tunnel CNAME behind Cloudflare's edge.

resource "cloudflare_dns_record" "uptime_kuma" {
  zone_id = var.cloudflare_zone_id
  name    = "uptime"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "stalwart_mail" {
  zone_id = var.cloudflare_zone_id
  name    = "mail"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "calibre_web" {
  zone_id = var.cloudflare_zone_id
  name    = "calibre"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "jellyfin" {
  zone_id = var.cloudflare_zone_id
  name    = "jellyfin"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

# docs.chronobyte.net is hosted on GitHub Pages (see .github/workflows/docs-pages.yml).
# CNAME points to <owner>.github.io and is DNS-only so GitHub can provision
# the Let's Encrypt certificate for the custom domain.
resource "cloudflare_dns_record" "docs" {
  zone_id = var.cloudflare_zone_id
  name    = "docs"
  content = "hexabyte8.github.io"
  type    = "CNAME"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "dashy" {
  zone_id = var.cloudflare_zone_id
  name    = "dashy"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}
