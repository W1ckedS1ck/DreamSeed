locals {
  cloud_prom = "grafanacloud-prom"

  dashboards = {
    node_exporter    = { gid = 1860 }
    mysql            = { gid = 7362 }
    nginx            = { gid = 17452 }
    redis            = { gid = 763 }
    victoria_metrics = { gid = 10229 }
  }

  raw = {
    for k, v in local.dashboards :
    k => try(
      jsondecode(data.http.dashboard[k].body),
      { id = null, title = k, gnetId = v.gid, templating = { list = [] } }
    )
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

data "http" "dashboard" {
  for_each = local.dashboards
  url      = "https://grafana.com/api/dashboards/${each.value.gid}/revisions/latest/download"
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
