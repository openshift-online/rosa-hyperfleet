# =============================================================================
# PagerDuty Service Module
#
# Creates a PagerDuty service and Events API v2 integration per region.
# Stores the integration key in AWS Secrets Manager for consumption
# by AlertManager via External Secrets.
# =============================================================================

locals {
  service_name = var.eph_prefix != "" ? "rrp-${var.eph_prefix}-${var.environment}-${var.region}" : "rrp-${var.environment}-${var.region}"
}

# =============================================================================
# PagerDuty Service
# =============================================================================

resource "pagerduty_service" "regional" {
  name              = local.service_name
  description       = "${var.service_description} (${var.environment}/${var.region})"
  escalation_policy = var.escalation_policy_id

  alert_creation          = "create_alerts_and_incidents"
  auto_resolve_timeout    = "null"
  acknowledgement_timeout = "null"
}

# =============================================================================
# PagerDuty Events API v2 Integration
#
# Generates a unique integration (routing) key per region. To invalidate
# a key, taint or destroy/recreate this resource.
# =============================================================================

resource "pagerduty_service_integration" "events_v2" {
  name    = "${local.service_name}-events-v2"
  service = pagerduty_service.regional.id
  vendor  = data.pagerduty_vendor.events_v2.id
}

data "pagerduty_vendor" "events_v2" {
  name = "Events API v2"
}

# =============================================================================
# AWS Secrets Manager — Integration Key
# =============================================================================

resource "aws_secretsmanager_secret" "pagerduty_integration_key" {
  name                    = "${var.regional_id}-pagerduty-integration-key"
  description             = "PagerDuty Events API v2 integration key for AlertManager"
  recovery_window_in_days = 0

  tags = {
    Name      = "${var.regional_id}-pagerduty-integration-key"
    Module    = "pagerduty-service"
    ManagedBy = "terraform"
  }
}

resource "aws_secretsmanager_secret_version" "pagerduty_integration_key" {
  secret_id = aws_secretsmanager_secret.pagerduty_integration_key.id

  secret_string = jsonencode({
    integration_key = pagerduty_service_integration.events_v2.integration_key
  })
}
