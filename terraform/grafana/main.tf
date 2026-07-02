locals {
  cloud_prom = "grafanacloud-prom"

  dashboards = {
    node_exporter    = { gid = 1860 }
    mysql            = { gid = 7362 }
    nginx            = { gid = 17452 }
    redis            = { gid = 763 }
    victoria_metrics = { gid = 10229 }
  }

  # Read dashboard JSONs from local cache, fallback to minimal stub
  raw = {
    for k, v in local.dashboards :
    k => try(
      jsondecode(file("${path.module}/.dashboards/${k}.json")),
      { id = null, title = k, gnetId = v.gid, templating = { list = [] } }
    )
  }

  # Apply per-dashboard transformations
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
      jsonencode(merge(local.raw["nginx"], {
        id       = null
        __inputs = []
        templating = merge(local.raw["nginx"].templating, {
          list = [for v in local.raw["nginx"].templating.list : v if v.name != "DS_PROMETHEUS"]
        })
      })),
      "$${DS_PROMETHEUS}", local.cloud_prom
    )
    redis = replace(
      jsonencode(merge(local.raw["redis"], {
        id = null
        templating = merge(local.raw["redis"].templating, {
          list = try([for v in local.raw["redis"].templating.list : merge(v, {
            query = v.name == "instance" ? "label_values(redis_up, instance)" : v.query
          }) if v.name != "namespace"], [])
        })
      })),
      "$${DS_PROM}", local.cloud_prom
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
}

resource "grafana_dashboard" "this" {
  for_each    = local.dashboards
  config_json = local.config[each.key]
  folder      = grafana_folder.dreamseed.id
  overwrite   = true
}
