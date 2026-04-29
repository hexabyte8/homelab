# Cloudflare — Technology Guide

> This guide explains what Cloudflare is, how DNS works, and how Cloudflare manages
> public DNS records for this homelab's domain.
> No prior DNS or networking experience required.

---

## What is DNS?

**DNS (Domain Name System)** is the internet's phone book. When you type a hostname
like `traefik.example.com` in your browser, DNS translates it to an IP address
(like `203.0.113.42`) that your computer can actually connect to.

```
Your browser types:          DNS lookup:              Server reached:
traefik.example.com    →    203.0.113.42       →    Web server at 203.0.113.42
   (domain name)            (IP address)
```

**Common DNS record types:**

| Type | Purpose | Example |
|------|---------|---------|
| A | Maps hostname → IPv4 address | `traefik.example.com → 1.2.3.4` |
| AAAA | Maps hostname → IPv6 address | `traefik.example.com → ::1` |
| CNAME | Maps hostname → another hostname | `www.example.com → example.com` |
| MX | Mail server for a domain | `example.com → mail.example.com` |
| SRV | Service location (port + hostname) | `_minecraft._tcp.homestead.example.com → port 25565` |
| TXT | Text information | Used for domain verification, SPF, DKIM |

---

## What is Cloudflare?

**Cloudflare** is a company that provides (among many things) **DNS hosting** and a
**reverse proxy/CDN (Content Delivery Network)**.

In this homelab, Cloudflare is used for:
1. **Authoritative DNS** — Cloudflare holds the DNS records for the public domain
2. **Proxied records (optional)** — when a record is "proxied" (orange cloud), traffic
   goes through Cloudflare's network, which provides DDoS protection and hides the real IP

**Why Cloudflare for a homelab?**
- Free tier is very generous
- Fast global DNS propagation
- Excellent OpenTofu/Terraform provider
- API for automated DNS management
- DDoS protection even on free tier

**References:**
- [Cloudflare documentation](https://developers.cloudflare.com/)
- [Cloudflare DNS documentation](https://developers.cloudflare.com/dns/)
- [Cloudflare OpenTofu/Terraform provider](https://registry.opentofu.org/providers/cloudflare/cloudflare/latest/docs)

---

## How Cloudflare is Configured in This Homelab

### DNS Records

All DNS records are managed by OpenTofu in `opentofu/cloudflare.tf`:

| Record | Type | Points To | Proxied | Purpose |
|--------|------|-----------|---------|---------|
| `@` (root) | A | Public IP | Depends | Root domain |
| `traefik` | A | Public IP | Depends | Traefik reverse proxy dashboard |
| `auth` | A | Public IP | Depends | Authentik authentication |
| `ptero` | A | Public IP | Depends | Pterodactyl game panel |
| `homestead` | A | Public IP | Depends | Modded Minecraft web |
| `files` | A | Public IP | Depends | File server |
| `_minecraft._tcp.homestead` | SRV | `homestead.<domain>:25565` | No | Minecraft SRV record |

> **Note:** `proxied = false` means DNS-only (grey cloud). The real IP is visible.
> For homelab services exposed via Tailscale, DNS-only is used since the traffic
> does not go through Cloudflare's proxy anyway.

### The SRV Record for Minecraft

A **SRV (Service) record** allows specifying a port alongside the hostname.
When Minecraft clients look up `homestead.example.com`, they find the SRV record
which tells them to connect to port 25565 on `homestead.example.com`.

```hcl
# opentofu/cloudflare.tf
resource "cloudflare_record" "minecraft_srv" {
  zone_id = var.cloudflare_zone_id
  name    = "_minecraft._tcp.homestead"
  type    = "SRV"
  data {
    service  = "_minecraft"
    proto    = "_tcp"
    name     = "homestead.${var.cloudflare_zone_name}"
    priority = 0
    weight   = 5
    port     = 25565
    target   = "homestead.${var.cloudflare_zone_name}"
  }
}
```

---

## Cloudflare Concepts

### Zone

A Cloudflare **zone** corresponds to a domain (e.g., `example.com`). All DNS records
for that domain live within the zone.

The zone has a unique **Zone ID** (a long alphanumeric string) that is required
by the OpenTofu provider.

### API Token vs API Key

Cloudflare offers two types of credentials:
- **API Token (recommended):** Scoped to specific permissions and zones — safer
- **Global API Key (legacy):** Full account access — avoid using this

This homelab uses an API Token with these permissions:
- Zone: `DNS` → Edit
- Zone: `Zone` → Read
- Account: `Cloudflare Tunnel` → Edit
- Account: `Zero Trust` → Edit

The last two permissions are required for OpenTofu to manage Cloudflare Tunnels via the `cloudflare_zero_trust_tunnel_cloudflared` and `cloudflare_zero_trust_tunnel_cloudflared_config` resources.

Stored in Bitwarden as `CLOUDFLARE_API_TOKEN`.

### Propagation

When you create or update a DNS record, the change must **propagate** across Cloudflare's
global DNS network. With Cloudflare, this typically takes **seconds to a few minutes**
(much faster than other DNS providers which can take hours).

---

## Managing DNS via OpenTofu

Normal operations use GitHub Actions to run OpenTofu automatically.

**To view current DNS records:**
```bash
# Check what OpenTofu has in state
tofu state list | grep cloudflare

# Show details of a specific record
tofu state show cloudflare_record.traefik
```

**To add a new DNS record:**

1. Edit `opentofu/cloudflare.tf`:
   ```hcl
   resource "cloudflare_record" "my_new_service" {
     zone_id = var.cloudflare_zone_id
     name    = "my-service"
     content = var.public_ip
     type    = "A"
     ttl     = 1        # 1 = automatic TTL
     proxied = false    # DNS-only, no Cloudflare proxy
   }
   ```

2. Commit and push to `main` — the `opentofu-apply.yml` workflow runs automatically

**Reference:** [Cloudflare OpenTofu provider documentation](https://registry.opentofu.org/providers/cloudflare/cloudflare/latest/docs/resources/record)

---

## Cloudflare Dashboard

Access the dashboard at [dash.cloudflare.com](https://dash.cloudflare.com).

**Key sections:**

| Section | What You'll Find |
|---------|----------------|
| Your domain → DNS | All DNS records — can be viewed/edited manually |
| Your domain → Overview | Zone ID and account information |
| Account settings | Account ID |
| Profile → API Tokens | Create/manage API tokens for OpenTofu |

---

## Finding Your Zone ID and Account ID

Both IDs are needed for OpenTofu and should be stored in Bitwarden.

**Zone ID:**
1. Go to [dash.cloudflare.com](https://dash.cloudflare.com)
2. Click on your domain
3. On the **Overview** page, scroll down to **API** section on the right side
4. Copy the **Zone ID**

**Account ID:**
1. On the same **Overview** page
2. Copy the **Account ID** (also in the API section)

---

## Common Troubleshooting

### DNS record not resolving

```bash
# Check if the record exists in Cloudflare
# Using the Cloudflare API:
curl -X GET \
  "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records?name=traefik.example.com" \
  -H "Authorization: Bearer <CLOUDFLARE_API_TOKEN>"

# Or using dig to query Cloudflare's nameservers directly:
dig @1.1.1.1 traefik.example.com A
```

### Records exist but Terraform wants to recreate them

This can happen after a Terraform state loss. Import the existing record:
```bash
# First find the record ID using the API (shown in the API response above)
tofu import cloudflare_record.traefik <ZONE_ID>/<RECORD_ID>
```

### API token errors

```bash
# Test your API token
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer <CLOUDFLARE_API_TOKEN>"
# Should return: {"result":{"status":"active"},"success":true,...}
```

If the token is expired or revoked:
1. Go to Cloudflare dashboard → Profile → API Tokens
2. Create a new token with the required permissions
3. Update the `CLOUDFLARE_API_TOKEN` in Bitwarden
4. Update the secret in Bitwarden Secrets Manager (used by GitHub Actions)
