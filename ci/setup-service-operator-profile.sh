#!/usr/bin/env bash

setup_operator_profile() {
  if [[ -z "${E2E_SERVICE_OPERATOR_PROFILE:-}" ]]; then
    local account_id
    account_id=$(aws sts get-caller-identity --profile rrp-rc --query Account --output text) || return 1
    if [[ ! "$account_id" =~ ^[0-9]{12}$ ]]; then
      echo "Invalid regional account ID for service-operator profile" >&2
      return 1
    fi
    cp "$AWS_CONFIG_FILE" "$1" || return 1
    chmod 600 "$1" || return 1
    export AWS_CONFIG_FILE="$1"
    export E2E_SERVICE_OPERATOR_PROFILE=rrp-service-operator

    # CI provisioning establishes this role's trust in the central account.
    aws configure set role_arn "arn:aws:iam::${account_id}:role/OrganizationAccountAccessRole" --profile "$E2E_SERVICE_OPERATOR_PROFILE" || return 1
    aws configure set source_profile rrp-central --profile "$E2E_SERVICE_OPERATOR_PROFILE" || return 1
  fi
  echo "ManagementCluster E2E service-operator caller:"
  aws sts get-caller-identity --profile "$E2E_SERVICE_OPERATOR_PROFILE" --query '{Account:Account,Arn:Arn}' --output json
}
