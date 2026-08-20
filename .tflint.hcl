plugin "aws" {
  enabled = true
  version = "0.40.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "aws_resource_missing_tags" {
  enabled = true
  tags    = ["function", "module"]

  # Pipeline modules are being deprecated — skip them entirely.
  exclude = [
    "aws_codepipeline",
    "aws_codebuild_project",
  ]
}
