# Hosted Cluster AutoNode (Karpenter)

AutoNode is the Karpenter-based autoscaling feature for ROSA HCP clusters. When enabled, a
Karpenter controller runs in the hosted control plane namespace on the management cluster and
provisions EC2 worker nodes in response to unschedulable pods — without requiring pre-defined
HyperShift NodePools.

## Overview

With AutoNode enabled:

- Karpenter provisions and terminates EC2 instances automatically based on workload demand.
- Customers define `OpenshiftEC2NodeClass` and `NodePool` resources on the guest cluster to
  control instance types, availability zones, and disruption behaviour.
- A dedicated IAM role (`karpenter-controller`) in the customer account grants Karpenter the
  EC2 permissions it needs.

AutoNode is GA in OCP 4.22 / ROSA HCP. See the
[ROSA HCP AutoNode documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cluster_administration/rosa-hcp-autonode)
for background on components and feature gates.

## Prerequisites

- OCP 4.22 or later (HyperShift Operator v0.1.75+)
- A Karpenter controller IAM role in the customer's AWS account (see below)

## Create the Karpenter Controller IAM Role

The Karpenter controller authenticates to AWS via IRSA (IAM Roles for Service Accounts). Create
the role in the customer AWS account before creating the cluster.

```bash
CLUSTER_NAME="my-autonode-cluster"
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Retrieve the OIDC provider URL after cluster OIDC setup (rosactl cluster-oidc create)
OIDC_PROVIDER="<oidc-issuer-url-without-https>"

NAMESPACE="clusters-${CLUSTER_NAME}"
SERVICE_ACCOUNT="karpenter"

# Trust policy — allows the Karpenter service account to assume this role
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name "${CLUSTER_NAME}-karpenter-controller" \
  --assume-role-policy-document file://trust-policy.json

# Attach the managed Karpenter controller policy
# (managed-cluster-config PR #2581 — policy name: rosa-hcp-karpenter-controller-policy)
aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-karpenter-controller" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/rosa-hcp-karpenter-controller-policy"

KARPENTER_ROLE_ARN=$(aws iam get-role \
  --role-name "${CLUSTER_NAME}-karpenter-controller" \
  --query Role.Arn --output text)

echo "Karpenter Controller Role ARN: ${KARPENTER_ROLE_ARN}"
```

## Create a Cluster with AutoNode Enabled

Pass the Karpenter controller role ARN when creating the cluster:

```bash
rosactl cluster create $CLUSTER_NAME \
  --region $REGION \
  --karpenter-role-arn $KARPENTER_ROLE_ARN
```

The platform API stores `karpenterControllerRoleArn` in the cluster spec. The HyperFleet adapter
reads this field and sets `spec.platform.aws.karpenterControllerRoleARN` on the HostedCluster CR,
which instructs HyperShift to deploy and configure the Karpenter controller in the hosted control
plane namespace.

## Verify AutoNode Is Active

After the cluster is ready, confirm the Karpenter controller is running on the management cluster:

```bash
# Requires MC kubeconfig — use `make ephemeral-bastion-mc` or `make int-bastion-mc`
kubectl get deployment -n clusters-${CLUSTER_NAME} karpenter-controller
kubectl logs -n clusters-${CLUSTER_NAME} deployment/karpenter-controller
```

Check AutoNode status in the HostedCluster:

```bash
kubectl get hostedcluster ${CLUSTER_NAME} -n clusters-${CLUSTER_NAME} \
  -o jsonpath='{.status.autoNode}'
```

## Configure AutoNode on the Guest Cluster

Once the cluster is ready, create an `OpenshiftEC2NodeClass` and a Karpenter `NodePool` on the
guest cluster.

### OpenshiftEC2NodeClass

```yaml
apiVersion: karpenter.sh/v1
kind: OpenshiftEC2NodeClass
metadata:
  name: default
  namespace: openshift-karpenter
spec:
  instanceProfile: "karpenter-node-instance-profile"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  metadataOptions:
    httpTokens: required
    httpPutResponseHopLimit: 1
```

### NodePool

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-purpose
  namespace: openshift-karpenter
spec:
  template:
    spec:
      nodeClassRef:
        name: default
      requirements:
        - key: node.kubernetes.io/instance-type
          operator: In
          values:
            - m5.xlarge
            - m5.2xlarge
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand
  disruption:
    consolidationPolicy: WhenUnderutilized
    budgets:
      - nodes: "10%"
  limits:
    cpu: "100"
    memory: "400Gi"
```

### ValidatingAdmissionPolicies

AutoNode enforces guard rails via ValidatingAdmissionPolicies on the guest cluster (deployed
automatically by managed-cluster-config):

- Instance types must have **at least 4 vCPUs** — `t3.micro`, `t3.small`, and `t3.nano` are
  rejected.
- Public IP addresses are disabled by default on the OpenshiftEC2NodeClass.

## Disabling AutoNode

AutoNode cannot be disabled via the platform API after cluster creation. To stop Karpenter from
provisioning new nodes, delete all `NodePool` resources on the guest cluster.

## Troubleshooting

| Symptom                           | Diagnosis                                                           |
| --------------------------------- | ------------------------------------------------------------------- |
| Karpenter pod in CrashLoopBackOff | Check IAM role trust policy and OIDC provider match                 |
| Nodes not provisioning            | Inspect `OpenshiftEC2NodeClass` status; verify subnet tags          |
| VAP rejects NodeClass             | Instance type must have ≥ 4 vCPUs                                   |
| Metrics missing                   | Confirm `observe-fleetsharding: "true"` annotation on HostedCluster |

For additional troubleshooting steps see the
[ROSA HCP AutoNode troubleshooting guide](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cluster_administration/rosa-hcp-autonode).

## References

- [ROSA HCP AutoNode documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cluster_administration/rosa-hcp-autonode)
- [Hosted Cluster Provisioning](hostedcluster-provisioning.md)
- [HyperShift PR #8166 — feature gate removal](https://github.com/openshift/hypershift/pull/8166)
- [Managed Policy PR #2581](https://github.com/openshift/managed-cluster-config/pull/2581)
