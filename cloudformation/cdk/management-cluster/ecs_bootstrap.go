package main

import (
	"fmt"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsec2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsecs"
	"github.com/aws/aws-cdk-go/awscdk/v2/awseks"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsiam"
	"github.com/aws/aws-cdk-go/awscdk/v2/awskms"
	"github.com/aws/aws-cdk-go/awscdk/v2/awslogs"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

type McEcsBootstrapProps struct {
	ClusterId            string
	Vpc                  awsec2.Vpc
	PrivateSubnets       *[]awsec2.ISubnet
	EksCluster           awseks.CfnCluster
	ClusterSecurityGroup awsec2.SecurityGroup
	ContainerImage       string
	RcAwsAccountId       string
	RepositoryUrl        string
	RepositoryBranch     string
}

// NewMcEcsBootstrap creates ECS Fargate cluster, task definition, and IAM for bootstrapping.
// Equivalent to terraform/modules/ecs-bootstrap (~620 lines of HCL).
func NewMcEcsBootstrap(scope constructs.Construct, id string, props *McEcsBootstrapProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))
	name := props.ClusterId

	// ECS Cluster
	ecsCluster := awsecs.NewCluster(c, jsii.String("Cluster"), &awsecs.ClusterProps{
		ClusterName:       jsii.String(fmt.Sprintf("%s-bootstrap", name)),
		ContainerInsights: jsii.Bool(true),
		Vpc:               props.Vpc,
	})

	// KMS + Log Group
	logsKey := awskms.NewKey(c, jsii.String("LogsKey"), &awskms.KeyProps{
		Description:       jsii.String(fmt.Sprintf("KMS key for %s bootstrap CloudWatch logs", name)),
		EnableKeyRotation: jsii.Bool(true),
	})
	logGroup := awslogs.NewLogGroup(c, jsii.String("LogGroup"), &awslogs.LogGroupProps{
		LogGroupName:  jsii.String(fmt.Sprintf("/ecs/%s-bootstrap", name)),
		Retention:     awslogs.RetentionDays_ONE_YEAR,
		EncryptionKey: logsKey,
	})

	// Task Role with EKS + SSM + Secrets access
	taskRole := awsiam.NewRole(c, jsii.String("TaskRole"), &awsiam.RoleProps{
		RoleName:  jsii.String(fmt.Sprintf("%s-bootstrap-task", name)),
		AssumedBy: awsiam.NewServicePrincipal(jsii.String("ecs-tasks.amazonaws.com"), nil),
	})
	taskRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions:   jsii.Strings("eks:DescribeCluster", "eks:ListClusters", "eks:AccessKubernetesApi"),
		Resources: jsii.Strings(*props.EksCluster.AttrArn()),
	}))
	taskRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings("ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"),
		Resources: jsii.Strings(fmt.Sprintf("arn:%s:ssm:%s:%s:parameter/%s/*",
			*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), *awscdk.Aws_ACCOUNT_ID(), name)),
	}))
	taskRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings("secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"),
		Resources: jsii.Strings(fmt.Sprintf("arn:%s:secretsmanager:%s:%s:secret:%s/*",
			*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), *awscdk.Aws_ACCOUNT_ID(), name)),
	}))

	// EKS access entry — cluster admin for bootstrap
	awseks.NewCfnAccessEntry(c, jsii.String("AccessEntry"), &awseks.CfnAccessEntryProps{
		ClusterName:  props.EksCluster.Name(),
		PrincipalArn: taskRole.RoleArn(),
		Type:         jsii.String("STANDARD"),
		AccessPolicies: &[]*awseks.CfnAccessEntry_AccessPolicyProperty{{
			PolicyArn: jsii.String("arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"),
			AccessScope: &awseks.CfnAccessEntry_AccessScopeProperty{
				Type: jsii.String("cluster"),
			},
		}},
	})

	// Security group
	bootstrapSG := awsec2.NewSecurityGroup(c, jsii.String("BootstrapSG"), &awsec2.SecurityGroupProps{
		Vpc:         props.Vpc,
		Description: jsii.String(fmt.Sprintf("Bootstrap ECS task SG for %s", name)),
	})
	props.ClusterSecurityGroup.AddIngressRule(bootstrapSG, awsec2.Port_Tcp(jsii.Number(443)),
		jsii.String("HTTPS from bootstrap task"), nil)

	// Fargate task definition
	taskDef := awsecs.NewFargateTaskDefinition(c, jsii.String("TaskDef"), &awsecs.FargateTaskDefinitionProps{
		Family:         jsii.String(fmt.Sprintf("%s-bootstrap", name)),
		Cpu:            jsii.Number(256),
		MemoryLimitMiB: jsii.Number(512),
		TaskRole:       taskRole,
	})
	taskDef.AddContainer(jsii.String("bootstrap"), &awsecs.ContainerDefinitionOptions{
		Image:     awsecs.ContainerImage_FromRegistry(jsii.String(props.ContainerImage), nil),
		Command:   jsii.Strings("/bin/bash", "-c", "/scripts/bootstrap-argocd.sh"),
		Essential: jsii.Bool(true),
		Environment: &map[string]*string{
			"CLUSTER_NAME":      props.EksCluster.Name(),
			"CLUSTER_TYPE":      jsii.String("management-cluster"),
			"CLUSTER_ID":        jsii.String(name),
			"RC_AWS_ACCOUNT_ID": jsii.String(props.RcAwsAccountId),
			"REPOSITORY_URL":    jsii.String(props.RepositoryUrl),
			"REPOSITORY_BRANCH": jsii.String(props.RepositoryBranch),
			"AWS_REGION":        awscdk.Aws_REGION(),
		},
		Logging: awsecs.LogDriver_AwsLogs(&awsecs.AwsLogDriverProps{
			LogGroup:     logGroup,
			StreamPrefix: jsii.String("bootstrap"),
		}),
	})

	_ = ecsCluster
}
