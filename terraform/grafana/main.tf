locals {
  cloud_prom = "grafanacloud-prom"

  # Pinned community dashboards (gid 1860/7362/17452/763/10229) — single
  # source of truth: the same JSON files provision the on-server Grafana
  # (ansible-roles/grafana). Reading them locally removes the plan-time
  # grafana.com dependency and the "revisions/latest" upstream drift that
  # used to silently rewrite live dashboards. Upstream refresh = re-download
  # into ansible-roles/grafana/files (a reviewable diff).
  dashboards = {
    node_exporter    = "node-exporter-full.json"
    mysql            = "mysql-database.json"
    nginx            = "nginx.json"
    redis            = "redis.json"
    victoria_metrics = "victoria-metrics-single-node.json"
  }

  raw = {
    # No try() fallback: a missing/corrupt file must abort the plan, never
    # overwrite live dashboards with a stub (same guarantee the old
    # data.http postcondition gave).
    for k, v in local.dashboards : k => jsondecode(file("${path.module}/../../ansible-roles/grafana/files/${v}"))
  }

  config = {
    node_exporter = replace(
      jsonencode(merge(local.raw["node_exporter"], {
        id = null
        templating = merge(local.raw["node_exporter"].templating, {
          list = [for v in local.raw["node_exporter"].templating.list : v if v.name != "ds_prometheus"]
        })
      })),
      "$${ds_prometheus}", local.cloud_prom
    )
    mysql = replace(
      jsonencode(merge(local.raw["mysql"], { id = null, __inputs = [] })),
      "$${DS_PROMETHEUS}", local.cloud_prom
    )
    nginx = replace(
      replace(
        jsonencode(merge(local.raw["nginx"], {
          id       = null
          __inputs = []
          templating = merge(local.raw["nginx"].templating, {
            list = [for v in local.raw["nginx"].templating.list : v if v.name != "DS_PROMETHEUS"]
          })
        })),
        "$${DS_PROMETHEUS}", local.cloud_prom
      ),
      # On-server Grafana provisions this datasource as name=uid="VictoriaMetrics"
      # (ansible-roles/grafana); Grafana Cloud only has grafanacloud-prom — rebind.
      "VictoriaMetrics", local.cloud_prom
    )
    redis = replace(
      replace(
        jsonencode(merge(local.raw["redis"], {
          id = null
          templating = merge(local.raw["redis"].templating, {
            list = try([for v in local.raw["redis"].templating.list : merge(v, {
              query = v.name == "instance" ? "label_values(redis_up, instance)" : v.query
            }) if v.name != "namespace"], [])
          })
        })),
        "$${DS_PROM}", local.cloud_prom
      ),
      # On-server Grafana provisions this datasource as name=uid="VictoriaMetrics"
      # (ansible-roles/grafana); Grafana Cloud only has grafanacloud-prom — rebind.
      "VictoriaMetrics", local.cloud_prom
    )
    victoria_metrics = replace(
      replace(
        jsonencode(merge(local.raw["victoria_metrics"], {
          id = null
          templating = merge(local.raw["victoria_metrics"].templating, {
            list = [for v in local.raw["victoria_metrics"].templating.list : v if v.name != "ds"]
          })
        })),
        "$${ds}", local.cloud_prom
      ),
      "$ds", local.cloud_prom
    )
  }
}

resource "grafana_folder" "dreamseed" {
  title = "DreamSeed (${terraform.workspace})"

  lifecycle {
    prevent_destroy = true
  }
}

resource "grafana_dashboard" "this" {
  for_each    = local.dashboards
  config_json = local.config[each.key]
  folder      = grafana_folder.dreamseed.id
  overwrite   = true

  lifecycle {
    prevent_destroy = true
  }
}
