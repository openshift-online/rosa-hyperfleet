#!/usr/bin/env bash
#
# terraform-install.sh - Install Terraform and dependencies for CodeBuild environment
#
# This script installs common dependencies (jq, boto3, etc.) and Terraform
# into the CodeBuild environment.

set -euo pipefail

echo "Installing dependencies..."
yum install -y unzip python3 jq gnupg2
pip3 install boto3 pyyaml

echo "Installing Terraform..."

TF_VERSION="1.15.3"
TF_PACKAGE="terraform_${TF_VERSION}_linux_amd64.zip"
TF_BASE_URL="https://releases.hashicorp.com/terraform/${TF_VERSION}"

# Download Terraform package and verification files
echo "Downloading Terraform ${TF_VERSION}..."
curl -sSfO "${TF_BASE_URL}/${TF_PACKAGE}"
curl -sSfO "${TF_BASE_URL}/terraform_${TF_VERSION}_SHA256SUMS"
curl -sSfO "${TF_BASE_URL}/terraform_${TF_VERSION}_SHA256SUMS.sig"

# Import HashiCorp GPG key
echo "Importing HashiCorp GPG key..."
gpg --batch --keyserver keyserver.ubuntu.com --recv-keys \
  C874011F0AB405110D02105534365D9472D7468F || \
gpg --batch --keyserver keys.openpgp.org --recv-keys \
  C874011F0AB405110D02105534365D9472D7468F || \
gpg --batch --keyserver pgp.mit.edu --recv-keys \
  C874011F0AB405110D02105534365D9472D7468F

# Verify GPG signature on SHA256SUMS
echo "Verifying GPG signature..."
if ! gpg --batch --verify "terraform_${TF_VERSION}_SHA256SUMS.sig" "terraform_${TF_VERSION}_SHA256SUMS"; then
  echo "❌ GPG signature verification failed"
  exit 1
fi
echo "✓ GPG signature verified"

# Verify checksum of Terraform package
echo "Verifying SHA256 checksum..."
if ! grep "${TF_PACKAGE}" "terraform_${TF_VERSION}_SHA256SUMS" | sha256sum -c -; then
  echo "❌ Checksum verification failed"
  exit 1
fi
echo "✓ Checksum verified"

# Install Terraform
echo "Installing Terraform..."
unzip -o "${TF_PACKAGE}" -d /tmp/tf-bin
mv /tmp/tf-bin/terraform /usr/local/bin/

# Cleanup
rm -f "${TF_PACKAGE}" "terraform_${TF_VERSION}_SHA256SUMS" "terraform_${TF_VERSION}_SHA256SUMS.sig"

terraform version
echo "✓ Terraform installation verified"