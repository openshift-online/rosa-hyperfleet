# Directories excluded from tag coverage enforcement.
# Each excluded directory gets a local .tflint.hcl that disables aws_resource_missing_tags.

rule "aws_resource_missing_tags" {
  enabled = false
}
