FROM registry.access.redhat.com/ubi9/ubi-minimal:9.7-1770267347

# Tool versions - update these and rebuild to upgrade
ARG KUBECTL_VERSION=v1.31.0
ARG HELM_VERSION=v3.16.0
ARG K9S_VERSION=v0.32.5
ARG STERN_VERSION=1.30.0
ARG YQ_VERSION=v4.44.3
ARG OC_VERSION=4.16.0
ARG TERRAFORM_VERSION=1.14.3

# Install base packages
RUN microdnf install -y \
      tar \
      gzip \
      unzip \
      jq \
      git \
      less \
      vim-enhanced \
      which \
      findutils \
      make \
      procps-ng \
      bind-utils \
      shadow-utils \
      postgresql \
      python3 \
      python3-pip \
      gnupg2 && \
    pip3 install --no-cache-dir boto3==1.35.86 pyyaml==6.0.2 && \
    microdnf clean all && \
    rm -rf /var/cache/yum

# Install AWS CLI v2
RUN curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# Install kubectl
RUN curl -sL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Install helm
RUN curl -sL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/linux-amd64/helm /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm && \
    rm -rf /tmp/linux-amd64

# Install k9s
RUN curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/k9s /usr/local/bin/k9s && \
    chmod +x /usr/local/bin/k9s

# Install stern
RUN curl -sL "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_amd64.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/stern /usr/local/bin/stern && \
    chmod +x /usr/local/bin/stern

# Install yq
RUN curl -sL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Install OpenShift CLI (oc)
RUN curl -sL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/oc /usr/local/bin/oc && \
    chmod +x /usr/local/bin/oc && \
    rm -f /tmp/kubectl /tmp/README.md

# Install Terraform (GPG-verified)
RUN set -euo pipefail && \
    TF_PACKAGE="terraform_${TERRAFORM_VERSION}_linux_amd64.zip" && \
    TF_BASE_URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}" && \
    curl -sSfO "${TF_BASE_URL}/${TF_PACKAGE}" && \
    curl -sSfO "${TF_BASE_URL}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" && \
    curl -sSfO "${TF_BASE_URL}/terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" && \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys \
      C874011F0AB405110D02105534365D9472D7468F || \
    gpg --batch --keyserver keys.openpgp.org --recv-keys \
      C874011F0AB405110D02105534365D9472D7468F || \
    gpg --batch --keyserver pgp.mit.edu --recv-keys \
      C874011F0AB405110D02105534365D9472D7468F && \
    gpg --batch --verify "terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" \
      "terraform_${TERRAFORM_VERSION}_SHA256SUMS" && \
    grep "${TF_PACKAGE}" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c - && \
    unzip -o "${TF_PACKAGE}" -d /tmp/tf-bin && \
    mv /tmp/tf-bin/terraform /usr/local/bin/ && \
    rm -rf "${TF_PACKAGE}" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
      "terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" /tmp/tf-bin

# Setup Terraform plugin cache directory
ENV TF_PLUGIN_CACHE_DIR=/opt/platform/.terraform.d/plugin-cache
RUN mkdir -p ${TF_PLUGIN_CACHE_DIR}

# Copy provider versions config and generator script (from repo root)
COPY --chown=65534:65534 terraform/provider-versions.yaml /tmp/provider-versions.yaml
COPY --chown=65534:65534 terraform/modules/platform-image/generate-provider-init.py /tmp/generate-provider-init.py

# Generate Terraform config and download providers into cache
RUN chmod +x /tmp/generate-provider-init.py && \
    python3 /tmp/generate-provider-init.py && \
    cd /tmp && \
    terraform init && \
    echo "" && \
    echo "✅ Providers cached successfully:" && \
    find ${TF_PLUGIN_CACHE_DIR} -name "terraform-provider-*" -type f | sort && \
    echo "" && \
    echo "Cache size:" && \
    du -sh ${TF_PLUGIN_CACHE_DIR} && \
    rm -rf /tmp/.terraform* /tmp/provider-init.tf /tmp/provider-versions.yaml /tmp/generate-provider-init.py

# Run as non-root
RUN mkdir -p /opt/platform && chown -R 65534:65534 /opt/platform
ENV HOME=/opt/platform
USER 65534
