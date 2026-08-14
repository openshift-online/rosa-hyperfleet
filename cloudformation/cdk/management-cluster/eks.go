package main

import (
	"fmt"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsec2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awseks"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsiam"
	"github.com/aws/aws-cdk-go/awscdk/v2/awskms"
	"github.com/aws/aws-cdk-go/awscdk/v2/awslogs"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

type McEksClusterProps struct {
	ClusterId            string
	ClusterVersion       string
	Vpc                  awsec2.Vpc
	PrivateSubnets       *[]awsec2.ISubnet
	ClusterSecurityGroup awsec2.SecurityGroup
}

type McEksClusterOutputs struct {
	Cluster awseks.CfnCluster
}

// NewMcEksCluster creates EKS cluster with Auto Mode, KMS encryption, and managed addons.
// Equivalent to terraform/modules/eks-cluster (~518 lines of HCL).
//
// Uses L1 (CfnCluster) because CDK's L2 eks.Cluster doesn't yet support Auto Mode
// compute config. When L2 catches up, this could shrink by ~40%.
func NewMcEksCluster(scope constructs.Construct, id string, props *McEksClusterProps) *McEksClusterOutputs {
	c := constructs.NewConstruct(scope, jsii.String(id))
	name := props.ClusterId

	// KMS — CloudWatch Logs encryption (FedRAMP AU-09)
	cwLogsKey := awskms.NewKey(c, jsii.String("CwLogsKey"), &awskms.KeyProps{
		Description:    jsii.String(fmt.Sprintf("KMS key for EKS cluster CloudWatch log group encryption (FedRAMP AU-09)")),
		EnableKeyRotation: jsii.Bool(true),
		PendingWindow:     awscdk.Duration_Days(jsii.Number(30)),
		Alias:             jsii.String(fmt.Sprintf("alias/%s-cloudwatch-logs", name)),
	})
	// Grant CW Logs service access
	cwLogsKey.GrantEncryptDecrypt(awsiam.NewServicePrincipal(jsii.String(
		fmt.Sprintf("logs.%s.amazonaws.com", *awscdk.Aws_REGION())), nil))

	// CloudWatch Log Group
	awslogs.NewLogGroup(c, jsii.String("EksLogGroup"), &awslogs.LogGroupProps{
		LogGroupName:  jsii.String(fmt.Sprintf("/aws/eks/%s/cluster", name)),
		Retention:     awslogs.RetentionDays_ONE_YEAR,
		EncryptionKey: cwLogsKey,
	})

	// KMS — EKS Secrets encryption
	secretsKey := awskms.NewKey(c, jsii.String("SecretsKey"), &awskms.KeyProps{
		Description:       jsii.String("KMS key for EKS cluster secrets encryption"),
		EnableKeyRotation: jsii.Bool(true),
		PendingWindow:     awscdk.Duration_Days(jsii.Number(7)),
		Alias:             jsii.String(fmt.Sprintf("alias/%s-eks-secrets", name)),
	})

	// EKS Cluster Service Role
	clusterRole := awsiam.NewRole(c, jsii.String("ClusterRole"), &awsiam.RoleProps{
		RoleName: jsii.String(fmt.Sprintf("%s-cluster-role", name)),
		AssumedBy: awsiam.NewServicePrincipal(jsii.String("eks.amazonaws.com"), &awsiam.ServicePrincipalOpts{
			Conditions: &map[string]interface{}{},
		}),
		ManagedPolicies: &[]awsiam.IManagedPolicy{
			awsiam.ManagedPolicy_FromAwsManagedPolicyName(jsii.String("AmazonEKSClusterPolicy")),
			awsiam.ManagedPolicy_FromAwsManagedPolicyName(jsii.String("AmazonEKSComputePolicy")),
			awsiam.ManagedPolicy_FromAwsManagedPolicyName(jsii.String("AmazonEKSBlockStoragePolicy")),
			awsiam.ManagedPolicy_FromAwsManagedPolicyName(jsii.String("AmazonEKSLoadBalancingPolicy")),
			awsiam.ManagedPolicy_FromAwsManagedPolicyName(jsii.String("AmazonEKSNetworkingPolicy")),
		},
	})
	// Auto Mode requires sts:TagSession
	clusterRole.AssumeRolePolicy().AddStatements(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions:    jsii.Strings("sts:TagSession"),
		Principals: &[]awsiam.IPrincipal{awsiam.NewServicePrincipal(jsii.String("eks.amazonaws.com"), nil)},
	}))
	secretsKey.GrantEncryptDecrypt(clusterRole)

	// Auto Mode Node Role
	nodeRole := awsiam.NewRole(c, jsii.String("AutoNodeRole"), &awsiam.RoleProps{
		RoleName: jsii.String(fmt.Sprintf("%s-auto-node-role", name)),
		AssumedBy: awsiam.NewCompositePrincipal(
			awsiam.NewServicePrincipal(jsii.String("ec2.amazonaws.com"), nil),
			awsiam.NewServicePrincipal(jsii.String("eks.amazonaws.com"), nil),
		),
		ManagedPolicies: &[]awsiam.IManagedPolicy{
			awsiam.ManagedPolicy_FromAwsManagedPolicyName(jsii.String("AmazonEKSWorkerNodeMinimalPolicy")),
			awsiam.ManagedPolicy_FromAwsManagedPolicyName(jsii.String("AmazonEC2ContainerRegistryPullOnly")),
		},
	})

	// Collect private subnet IDs
	subnetIds := make([]*string, 0)
	for _, s := range *props.PrivateSubnets {
		subnetIds = append(subnetIds, s.SubnetId())
	}

	// EKS Cluster (L1 — Auto Mode not yet in L2)
	cluster := awseks.NewCfnCluster(c, jsii.String("Cluster"), &awseks.CfnClusterProps{
		Name:    jsii.String(name),
		Version: jsii.String(props.ClusterVersion),
		RoleArn: clusterRole.RoleArn(),
		BootstrapSelfManagedAddons: jsii.Bool(false),
		AccessConfig: &awseks.CfnCluster_AccessConfigProperty{
			AuthenticationMode: jsii.String("API_AND_CONFIG_MAP"),
		},
		EncryptionConfig: &[]*awseks.CfnCluster_EncryptionConfigProperty{{
			Resources: jsii.Strings("secrets"),
			Provider:  &awseks.CfnCluster_ProviderProperty{KeyArn: secretsKey.KeyArn()},
		}},
		ResourcesVpcConfig: &awseks.CfnCluster_ResourcesVpcConfigProperty{
			SubnetIds:             &subnetIds,
			EndpointPrivateAccess: jsii.Bool(true),
			EndpointPublicAccess:  jsii.Bool(false),
			SecurityGroupIds:      jsii.Strings(*props.ClusterSecurityGroup.SecurityGroupId()),
		},
		ComputeConfig: &awseks.CfnCluster_ComputeConfigProperty{
			Enabled:     jsii.Bool(true),
			NodePools:   jsii.Strings("system"),
			NodeRoleArn: nodeRole.RoleArn(),
		},
		KubernetesNetworkConfig: &awseks.CfnCluster_KubernetesNetworkConfigProperty{
			ElasticLoadBalancing: &awseks.CfnCluster_ElasticLoadBalancingProperty{Enabled: jsii.Bool(true)},
		},
		StorageConfig: &awseks.CfnCluster_StorageConfigProperty{
			BlockStorage: &awseks.CfnCluster_BlockStorageProperty{Enabled: jsii.Bool(true)},
		},
		Logging: &awseks.CfnCluster_LoggingProperty{
			ClusterLogging: &awseks.CfnCluster_ClusterLoggingProperty{
				EnabledTypes: &[]*awseks.CfnCluster_LoggingTypeConfigProperty{
					{Type: jsii.String("api")},
					{Type: jsii.String("audit")},
					{Type: jsii.String("authenticator")},
					{Type: jsii.String("controllerManager")},
					{Type: jsii.String("scheduler")},
				},
			},
		},
	})

	// Addons
	for _, addon := range []struct{ name, config string }{
		{"coredns", ""},
		{"metrics-server", ""},
		{"eks-pod-identity-agent", ""},
		{"aws-secrets-store-csi-driver-provider", `{"secrets-store-csi-driver":{"syncSecret":{"enabled":true}}}`},
	} {
		props := &awseks.CfnAddonProps{
			ClusterName: cluster.Name(),
			AddonName:   jsii.String(addon.name),
		}
		if addon.config != "" {
			props.ConfigurationValues = jsii.String(addon.config)
		}
		awseks.NewCfnAddon(c, jsii.String(fmt.Sprintf("Addon-%s", addon.name)), props)
	}

	return &McEksClusterOutputs{Cluster: cluster}
}
