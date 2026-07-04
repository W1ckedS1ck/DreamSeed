output "zone_ids" {
  description = "Map of zone names to IDs"
  value = {
    for k, z in data.cloudflare_zone.this : k => z.id
  }
}

output "cache_ruleset_ids" {
  description = "Map of zone names to ruleset IDs"
  value = {
    for k, r in cloudflare_ruleset.cache : k => r.id
  }
}
