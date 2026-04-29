
# This resource is for your root domain, pointing to your public IP.
resource "cloudflare_dns_record" "root_record" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  content = var.public_ip
  type    = "A"
  ttl     = 1
  proxied = true
}

# Resend DNS records for outbound email sending from @chronobyte.net
# These allow Resend to send email on behalf of chronobyte.net with proper DKIM/SPF.

resource "cloudflare_dns_record" "resend_dkim" {
  zone_id = var.cloudflare_zone_id
  name    = "resend._domainkey"
  content = "p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDEk+PiCzh/TTLE3Hh5XI6qF4Gq1zr7nIous7YTC1vJT9v4CexIJ+R7CWonpgUm560nfeVEgsy1Q7gJFt+Iwt12ao7o9q2/5AuuqTkmrWjzWmjdz0KioWZ4W6Cwh5VnPLYNDLB/++cXqmXrz0Bjtm8cCQ7ODc95G+KiB22dQMzwIwIDAQAB"
  type    = "TXT"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "resend_spf_mx" {
  zone_id  = var.cloudflare_zone_id
  name     = "send"
  content  = "feedback-smtp.us-east-1.amazonses.com"
  type     = "MX"
  ttl      = 1
  proxied  = false
  priority = 10
}

resource "cloudflare_dns_record" "resend_spf_txt" {
  zone_id = var.cloudflare_zone_id
  name    = "send"
  content = "v=spf1 include:amazonses.com ~all"
  type    = "TXT"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "resend_dmarc" {
  zone_id = var.cloudflare_zone_id
  name    = "_dmarc"
  content = "v=DMARC1; p=none;"
  type    = "TXT"
  ttl     = 1
  proxied = false
}
