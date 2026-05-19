# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Current AWS region
data "aws_region" "current" {}
