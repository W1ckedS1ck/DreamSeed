config {
  call_module_type = "none"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.38.0" # renovate: depName=terraform-linters/tflint-ruleset-aws
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

plugin "hcloud" {
  enabled = true
  version = "0.1.0" # renovate: depName=terraform-linters/tflint-ruleset-hcloud
  source  = "github.com/terraform-linters/tflint-ruleset-hcloud"
}

plugin "grafana" {
  enabled = true
  version = "0.2.1" # renovate: depName=terraform-linters/tflint-ruleset-grafana
  source  = "github.com/terraform-linters/tflint-ruleset-grafana"
}
