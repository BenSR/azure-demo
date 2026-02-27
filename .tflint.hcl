# TFLint configuration — used by CI (tflint --recursive) and local dev.
#
# Run locally:
#   tflint --init --config=.tflint.hcl
#   tflint --recursive --config=.tflint.hcl

plugin "azurerm" {
  enabled = true
  version = "0.28.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# Fail on deprecated resources and unsupported attributes in azurerm ~3.110.
rule "azurerm_resource_missing_tags" {
  enabled = false # Tags enforced by Terraform module convention, not TFLint.
}
