#!/bin/bash
set -euo pipefail

# Get account ID with error checking
if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --no-cli-pager 2>/dev/null); then
    echo "❌ Error: Failed to get AWS account ID. Check your AWS credentials."
    exit 1
fi

if [[ -z "$ACCOUNT_ID" || ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "❌ Error: Invalid AWS account ID: '$ACCOUNT_ID'"
    exit 1
fi

REGION=${1:-$(aws configure get region 2>/dev/null)}
REGION=${REGION:-us-east-1}
BUCKET_NAME="terraform-state-${ACCOUNT_ID}"

echo "Bootstrapping Terraform State in $REGION..."
echo "Bucket: $BUCKET_NAME"
echo ""

# Function to apply bucket security settings
apply_bucket_security() {
    echo "Applying security settings to bucket $BUCKET_NAME..."

    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled \
        --region "$REGION"

    aws s3api put-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' \
        --region "$REGION"

    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --region "$REGION"

    # Apply bucket policy to allow cross-account access from AWS Organizations
    echo "Applying bucket policy for cross-account access..."
    cat > /tmp/bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCrossAccountAccessFromOrganization",
      "Effect": "Allow",
      "Principal": "*",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "\${ORGANIZATION_ID}"
        }
      }
    }
  ]
}
EOF

    # Get Organization ID (if account is part of an organization)
    if ORGANIZATION_ID=$(aws organizations describe-organization --query 'Organization.Id' --output text 2>/dev/null); then
        echo "  Organization ID: $ORGANIZATION_ID"
        # Substitute the org ID in the policy
        sed -i "s/\${ORGANIZATION_ID}/${ORGANIZATION_ID}/g" /tmp/bucket-policy.json

        aws s3api put-bucket-policy \
            --bucket "$BUCKET_NAME" \
            --policy file:///tmp/bucket-policy.json \
            --region "$REGION"

        echo "✅ Cross-account bucket policy applied (AWS Organizations)"
        rm -f /tmp/bucket-policy.json
    else
        echo "⚠️  Account not in AWS Organization - skipping cross-account policy"
        echo "   Note: Cross-account Terraform state access will not work without manual bucket policy"
        rm -f /tmp/bucket-policy.json
    fi

    echo "✅ Security settings applied"
}

# Create S3 Bucket
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "✅ Bucket $BUCKET_NAME already exists."
    apply_bucket_security
else
    echo "Creating bucket $BUCKET_NAME..."
    if [[ "$REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --create-bucket-configuration LocationConstraint="$REGION" --region "$REGION"
    fi
    echo "✅ Bucket created successfully"
    apply_bucket_security
fi

echo ""
echo "✅ Bootstrap complete."
echo "   State bucket: $BUCKET_NAME"
echo "   Locking: lockfile (stored in S3)"
