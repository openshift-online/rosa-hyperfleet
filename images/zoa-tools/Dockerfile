FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

ARG OC_VERSION="stable-4.17"
ARG AWS_CLI_VERSION="awscli-exe-linux-x86_64.zip"
ARG YQ_VERSION="v4.44.3"

# System packages
RUN microdnf install -y \
        bash \
        jq \
        python3 \
        tar \
        gzip \
        unzip \
        curl \
        ca-certificates \
        shadow-utils \
    && microdnf clean all

# kubectl + oc (from OpenShift mirror)
RUN curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" \
        -o /tmp/oc.tar.gz && \
    tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc kubectl && \
    chmod +x /usr/local/bin/oc /usr/local/bin/kubectl && \
    rm -f /tmp/oc.tar.gz

# AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/${AWS_CLI_VERSION}" -o /tmp/awscliv2.zip && \
    unzip -qo /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# yq
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
        -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Non-root user
RUN useradd -r -u 1001 -g 0 -d /home/zoa -s /bin/bash zoa && \
    mkdir -p /home/zoa /artifacts /zoa && \
    chown -R 1001:0 /home/zoa /artifacts /zoa && \
    chmod -R g=u /home/zoa /artifacts /zoa

USER 1001
WORKDIR /home/zoa

# Validate installs
RUN kubectl version --client && \
    oc version --client && \
    aws --version && \
    jq --version && \
    yq --version
