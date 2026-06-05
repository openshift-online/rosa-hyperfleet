locals {
  table_name  = "${var.regional_id}-zoa-executions"
  bucket_name = "${var.regional_id}-zoa-outputs-${data.aws_caller_identity.current.account_id}"
  kms_alias   = "alias/${var.regional_id}-zoa"

  common_tags = {
    Component = "zoa"
    ManagedBy = "terraform"
  }
}
