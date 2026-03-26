terraform {
  required_version = "1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.28.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.0"
    }
  }
}
