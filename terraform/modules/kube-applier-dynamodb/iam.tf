# =============================================================================
# Backend IAM Role
#
# NOTE: The backend IAM role (for the RC-side backend service that reads/writes
# desire and status tables across all MCs) is intentionally NOT created here.
#
# This module is invoked once per MC with a separate state file per MC. Creating
# a shared RC-scoped role here would cause an EntityAlreadyExists collision when
# the second MC is provisioned. The backend role will be added to the RC-level
# kube-applier module (or a dedicated module) when the backend service is built.
# =============================================================================

