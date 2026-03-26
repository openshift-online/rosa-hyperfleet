# =============================================================================
# Maestro Agent IoT Provisioning Module - Version Constraints
# =============================================================================

terraform {
  required_version = "1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.28.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.12.0"
    }
  }
}
