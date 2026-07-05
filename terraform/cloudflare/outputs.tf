output "zone_ids" {
  description = "Map of zone names to IDs"
  value = {
    for k, z in data.cloudflare_zone.this : k => z.id
  }
}

output "page_rules" {
  description = "Map of page rule targets to IDs"
  value = {
    for k, r in cloudflare_page_rule.cache_all : k => {
      id     = r.id
      target = r.target
      status = r.status
    }
  }
}
