terraform {
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56.0"
    }
    pagerduty = {
      source  = "PagerDuty/pagerduty"
      version = ">= 3.0"
    }
  }
}
