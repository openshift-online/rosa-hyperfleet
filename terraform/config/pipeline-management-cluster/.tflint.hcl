# Directories excluded from tag coverage enforcement.
# Each excluded directory gets a local .tflint.hcl that disables aws_resource_missing_tags.

plugin "aws" {
  enabled = true
  version = "0.40.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "aws_resource_missing_tags" {
  enabled = false
}
