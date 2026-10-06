terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}
