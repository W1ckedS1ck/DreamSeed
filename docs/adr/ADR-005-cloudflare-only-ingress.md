# ADR-005: Cloudflare-only ingress to origins

- **Status:** Accepted

## Context

The site sits behind Cloudflare (CDN, WAF, DDoS protection, rate limiting on `/manager/`). If origins accept traffic from the whole internet, attackers can bypass every edge control by resolving the origin IP.

## Decision

Origin firewalls (AWS security groups / Hetzner firewalls) allow inbound 80/443 **only from Cloudflare's published IP ranges**, refreshed into Terraform on every plan. Visitor real IPs are restored via `CF-Connecting-IP` + `ngx_http_realip_module`. SSH is the only other open port (Ansible management, fail2ban-guarded).

## Consequences

- Direct-to-origin attacks on 80/443 are structurally impossible, not just filtered
- The origin cannot serve traffic if Cloudflare is down — accepted trade-off; the edge is also the DNS/CDN, so users would not reach the site anyway
- Firewall rules depend on Cloudflare's published ranges staying current — automated via data sources rather than a manual list
