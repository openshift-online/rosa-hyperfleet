#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  remove-codebuild-webhooks.sh [--region REGION] PROJECT_NAME...

Removes CodeBuild webhooks without deleting the CodeBuild projects or
CodePipelines. Existing projects are checked before deletion.
EOF
}

region_args=()
projects=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --region)
            [ "$#" -ge 2 ] || { echo "ERROR: --region requires a value" >&2; exit 2; }
            region_args=(--region "$2")
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -* )
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            projects+=("$1")
            shift
            ;;
    esac
done

if [ "${#projects[@]}" -eq 0 ]; then
    echo "ERROR: At least one CodeBuild project name is required" >&2
    usage >&2
    exit 2
fi

failed=0
for project_name in "${projects[@]}"; do
    existing_project=$(aws codebuild batch-get-projects \
        --names "$project_name" \
        --query 'projects[0].name' \
        --output text \
        "${region_args[@]}" \
        --no-cli-pager 2>/dev/null || true)

    if [ "$existing_project" != "$project_name" ]; then
        echo "ERROR: CodeBuild project not found: $project_name" >&2
        failed=1
        continue
    fi

    delete_output=""
    if delete_output=$(aws codebuild delete-webhook \
        --project-name "$project_name" \
        "${region_args[@]}" \
        --no-cli-pager 2>&1); then
        echo "Removed CodeBuild webhook: $project_name"
    elif grep -q "ResourceNotFoundException" <<<"$delete_output"; then
        echo "No CodeBuild webhook found: $project_name"
    else
        echo "ERROR: Failed to remove CodeBuild webhook: $project_name" >&2
        echo "$delete_output" >&2
        failed=1
    fi
done

exit "$failed"
