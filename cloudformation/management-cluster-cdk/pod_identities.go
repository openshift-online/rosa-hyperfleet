package main

import (
	"fmt"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awseks"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsiam"
	"github.com/aws/aws-cdk-go/awscdk/v2/awssecretsmanager"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// podIdentityRole creates an IAM role trusted by pods.eks.amazonaws.com and
// binds it to a namespace/serviceAccount via EKS Pod Identity Association.
// This helper replaces the boilerplate repeated across 7 TF modules.
func podIdentityRole(
	scope constructs.Construct,
	id string,
	roleName string,
	clusterName *string,
	namespace string,
	serviceAccount string,
) awsiam.Role {
	role := awsiam.NewRole(scope, jsii.String(id), &awsiam.RoleProps{
		RoleName: jsii.String(roleName),
		AssumedBy: awsiam.NewServicePrincipal(jsii.String("pods.eks.amazonaws.com"), &awsiam.ServicePrincipalOpts{
			Conditions: &map[string]interface{}{},
		}),
	})
	// sts:TagSession for Pod Identity
	role.AssumeRolePolicy().AddStatements(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions:    jsii.Strings("sts:TagSession"),
		Principals: &[]awsiam.IPrincipal{awsiam.NewServicePrincipal(jsii.String("pods.eks.amazonaws.com"), nil)},
	}))

	awseks.NewCfnPodIdentityAssociation(scope, jsii.String(id+"Assoc"), &awseks.CfnPodIdentityAssociationProps{
		ClusterName:    clusterName,
		Namespace:      jsii.String(namespace),
		ServiceAccount: jsii.String(serviceAccount),
		RoleArn:        role.RoleArn(),
	})

	return role
}

// ---------------------------------------------------------------------------
// DNS Pod Identity (terraform/modules/dns-pod-identity)
// ---------------------------------------------------------------------------

type DnsPodIdentityProps struct {
	ManagementId           string
	EksClusterName         *string
	DnsZoneOperatorRoleArn string
}

func NewDnsPodIdentity(scope constructs.Construct, id string, props *DnsPodIdentityProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))

	role := podIdentityRole(c, "DnsOperator",
		fmt.Sprintf("%s-dns-operator", props.ManagementId),
		props.EksClusterName, "hypershift", "external-dns")

	role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions:   jsii.Strings("sts:AssumeRole"),
		Resources: jsii.Strings(props.DnsZoneOperatorRoleArn),
	}))

	// cert-manager uses the same role
	awseks.NewCfnPodIdentityAssociation(c, jsii.String("CertMgrAssoc"), &awseks.CfnPodIdentityAssociationProps{
		ClusterName:    props.EksClusterName,
		Namespace:      jsii.String("cert-manager"),
		ServiceAccount: jsii.String("cert-manager"),
		RoleArn:        role.RoleArn(),
	})
}

// ---------------------------------------------------------------------------
// HyperShift OIDC (terraform/modules/hypershift-oidc)
// ---------------------------------------------------------------------------

type HypershiftOidcProps struct {
	ManagementId         string
	EksClusterName       *string
	OidcBucketName       string
	OidcBucketRegion     string
	OidcWriterRoleArn    string
	OidcCloudfrontDomain string
}

func NewHypershiftOidc(scope constructs.Construct, id string, props *HypershiftOidcProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))
	name := props.ManagementId

	// Operator role
	opRole := podIdentityRole(c, "Operator",
		fmt.Sprintf("%s-hypershift-operator", name),
		props.EksClusterName, "hypershift", "operator")

	opRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings(
			"ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
			"ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
			"ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
			"ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules",
			"ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints",
			"ec2:DescribeVpcEndpoints", "ec2:ModifyVpcEndpoint",
			"ec2:DescribeVpcs", "ec2:DescribeSubnets",
			"ec2:CreateTags", "ec2:DeleteTags",
			"elasticloadbalancing:DescribeLoadBalancers",
			"elasticloadbalancing:DescribeTargetGroups"),
		Resources: jsii.Strings("*"),
	}))

	if props.OidcWriterRoleArn != "" {
		opRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
			Actions:   jsii.Strings("sts:AssumeRole"),
			Resources: jsii.Strings(props.OidcWriterRoleArn),
		}))
	}

	// Installer role
	instRole := podIdentityRole(c, "Installer",
		fmt.Sprintf("%s-hypershift-installer", name),
		props.EksClusterName, "hypershift-install", "hypershift-installer")

	instRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings("secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"),
		Resources: jsii.Strings(fmt.Sprintf("arn:%s:secretsmanager:%s:%s:secret:hypershift/*",
			*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), *awscdk.Aws_ACCOUNT_ID())),
	}))

	// External Secrets Operator role
	esoRole := podIdentityRole(c, "ExternalSecrets",
		fmt.Sprintf("%s-external-secrets", name),
		props.EksClusterName, "external-secrets", "external-secrets")

	esoRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings("ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"),
		Resources: jsii.Strings(fmt.Sprintf("arn:%s:ssm:%s:%s:parameter/*",
			*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), *awscdk.Aws_ACCOUNT_ID())),
	}))

	// HyperShift config secret
	awssecretsmanager.NewSecret(c, jsii.String("ConfigSecret"), &awssecretsmanager.SecretProps{
		SecretName: jsii.String(fmt.Sprintf("hypershift/%s-config", name)),
		SecretStringValue: awscdk.SecretValue_UnsafePlainText(jsii.String(fmt.Sprintf(
			`{"bucket":"%s","region":"%s","issuerUrl":"https://%s","writerRoleArn":"%s"}`,
			props.OidcBucketName, props.OidcBucketRegion,
			props.OidcCloudfrontDomain, props.OidcWriterRoleArn))),
	})
}

// ---------------------------------------------------------------------------
// Prometheus Remote Write (terraform/modules/prometheus-remote-write)
// ---------------------------------------------------------------------------

type PrometheusRemoteWriteProps struct {
	ManagementId         string
	EksClusterName       *string
	RegionalAwsAccountId string
}

func NewPrometheusRemoteWrite(scope constructs.Construct, id string, props *PrometheusRemoteWriteProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))

	role := podIdentityRole(c, "Prometheus",
		fmt.Sprintf("%s-prometheus", props.ManagementId),
		props.EksClusterName, "monitoring", "sigv4-proxy")

	role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings("execute-api:Invoke"),
		Resources: jsii.Strings(fmt.Sprintf("arn:%s:execute-api:%s:%s:*/*/POST/api/v1/receive",
			*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), props.RegionalAwsAccountId)),
	}))
}

// ---------------------------------------------------------------------------
// Loki Log Forwarder (terraform/modules/loki-log-forwarder)
// ---------------------------------------------------------------------------

type LokiLogForwarderProps struct {
	ManagementId         string
	EksClusterName       *string
	RegionalAwsAccountId string
}

func NewLokiLogForwarder(scope constructs.Construct, id string, props *LokiLogForwarderProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))

	role := podIdentityRole(c, "LokiForwarder",
		fmt.Sprintf("%s-loki-forwarder", props.ManagementId),
		props.EksClusterName, "vector", "sigv4-proxy-logs")

	role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings("execute-api:Invoke"),
		Resources: jsii.Strings(fmt.Sprintf("arn:%s:execute-api:%s:%s:*/*/POST/loki/api/v1/push",
			*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), props.RegionalAwsAccountId)),
	}))
}

// ---------------------------------------------------------------------------
// CloudWatch Exporter (terraform/modules/cloudwatch-exporter)
// ---------------------------------------------------------------------------

type CloudWatchExporterProps struct {
	ManagementId   string
	EksClusterName *string
}

func NewCloudWatchExporter(scope constructs.Construct, id string, props *CloudWatchExporterProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))

	role := podIdentityRole(c, "CwExporter",
		fmt.Sprintf("%s-cloudwatch-exporter", props.ManagementId),
		props.EksClusterName, "monitoring", "yace-cw-exporter")

	role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings(
			"cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics",
			"cloudwatch:ListMetrics", "cloudwatch:DescribeAlarms",
			"tag:GetResources", "apigateway:GET",
			"rds:DescribeDBInstances", "rds:DescribeDBClusters",
			"elasticloadbalancing:DescribeLoadBalancers",
			"elasticloadbalancing:DescribeTargetGroups",
			"iam:ListAccountAliases"),
		Resources: jsii.Strings("*"),
	}))
}

// ---------------------------------------------------------------------------
// kube-applier (terraform/modules/kube-applier)
// ---------------------------------------------------------------------------

type KubeApplierProps struct {
	ManagementId   string
	EksClusterName *string
	RcAwsAccountId string
}

func NewKubeApplier(scope constructs.Construct, id string, props *KubeApplierProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))
	name := props.ManagementId

	role := podIdentityRole(c, "KubeApplier",
		fmt.Sprintf("%s-kube-applier", name),
		props.EksClusterName, "kube-applier", "kube-applier")

	// DynamoDB specs (read + streams)
	role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings(
			"dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan",
			"dynamodb:DescribeTable", "dynamodb:GetRecords", "dynamodb:GetShardIterator",
			"dynamodb:DescribeStream", "dynamodb:ListStreams"),
		Resources: jsii.Strings(
			fmt.Sprintf("arn:%s:dynamodb:%s:%s:table/%s-specs-*",
				*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), props.RcAwsAccountId, name),
			fmt.Sprintf("arn:%s:dynamodb:%s:%s:table/%s-specs-*/stream/*",
				*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), props.RcAwsAccountId, name),
		),
	}))

	// DynamoDB status (read-write)
	role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings(
			"dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
			"dynamodb:DeleteItem", "dynamodb:BatchWriteItem",
			"dynamodb:Query", "dynamodb:Scan", "dynamodb:DescribeTable"),
		Resources: jsii.Strings(fmt.Sprintf("arn:%s:dynamodb:%s:%s:table/%s-status-*",
			*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), props.RcAwsAccountId, name)),
	}))
}

// ---------------------------------------------------------------------------
// ZOA Job Pod Identity (terraform/modules/zoa-job-pod-identity)
// ---------------------------------------------------------------------------

type ZoaJobPodIdentityProps struct {
	ManagementId        string
	EksClusterName      *string
	ZoaOutputsBucketArn string
	ZoaKmsKeyArn        string
}

func NewZoaJobPodIdentity(scope constructs.Construct, id string, props *ZoaJobPodIdentityProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))
	name := props.ManagementId

	// Single role shared across all ZOA service accounts
	role := podIdentityRole(c, "ZoaJob",
		fmt.Sprintf("%s-zoa-job", name),
		props.EksClusterName, "zoa-jobs", "zoa-uploader")

	role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions:   jsii.Strings("s3:PutObject", "s3:PutObjectAcl"),
		Resources: jsii.Strings(fmt.Sprintf("%s/*", props.ZoaOutputsBucketArn)),
	}))
	role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions:   jsii.Strings("kms:GenerateDataKey", "kms:Decrypt"),
		Resources: jsii.Strings(props.ZoaKmsKeyArn),
	}))
	role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings(
			"eks:DescribeCluster", "eks:ListClusters",
			"ec2:DescribeInstances", "ec2:DescribeSubnets",
			"ec2:DescribeVpcs", "ec2:DescribeSecurityGroups"),
		Resources: jsii.Strings("*"),
	}))

	// Additional service account bindings (same role)
	for _, sa := range []string{"zoa-aws-read", "zoa-aws-write", "zoa-breakglass-read", "zoa-breakglass-write"} {
		awseks.NewCfnPodIdentityAssociation(c, jsii.String(fmt.Sprintf("Zoa-%s", sa)),
			&awseks.CfnPodIdentityAssociationProps{
				ClusterName:    props.EksClusterName,
				Namespace:      jsii.String("zoa-jobs"),
				ServiceAccount: jsii.String(sa),
				RoleArn:        role.RoleArn(),
			})
	}
}

// ---------------------------------------------------------------------------
// Grafana CloudWatch Logs (terraform/modules/grafana-cloudwatch-logs, mode=reader)
// ---------------------------------------------------------------------------

type GrafanaCloudWatchLogsProps struct {
	RegionalId           string
	GrafanaRoleAccountId string
}

func NewGrafanaCloudWatchLogs(scope constructs.Construct, id string, props *GrafanaCloudWatchLogsProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))

	awsiam.NewRole(c, jsii.String("GrafanaReader"), &awsiam.RoleProps{
		RoleName: jsii.String(fmt.Sprintf("%s-grafana-cw-logs-reader", props.RegionalId)),
		AssumedBy: awsiam.NewArnPrincipal(jsii.String(fmt.Sprintf(
			"arn:%s:iam::%s:role/%s-grafana-cloudwatch",
			*awscdk.Aws_PARTITION(), props.GrafanaRoleAccountId, props.RegionalId))),
		InlinePolicies: &map[string]awsiam.PolicyDocument{
			"cloudwatch-logs-read": awsiam.NewPolicyDocument(&awsiam.PolicyDocumentProps{
				Statements: &[]awsiam.PolicyStatement{
					awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
						Actions: jsii.Strings(
							"logs:GetLogEvents", "logs:GetLogRecord", "logs:GetQueryResults",
							"logs:DescribeLogGroups", "logs:DescribeLogStreams",
							"logs:StartQuery", "logs:StopQuery", "logs:FilterLogEvents",
							"cloudwatch:ListMetrics"),
						Resources: jsii.Strings("*"),
					}),
				},
			}),
		},
	})
}
