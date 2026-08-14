package main

import (
	"fmt"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsec2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsecs"
	"github.com/aws/aws-cdk-go/awscdk/v2/awseks"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsiam"
	"github.com/aws/aws-cdk-go/awscdk/v2/awskms"
	"github.com/aws/aws-cdk-go/awscdk/v2/awslambda"
	"github.com/aws/aws-cdk-go/awscdk/v2/awslogs"
	"github.com/aws/aws-cdk-go/awscdk/v2/customresources"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

type McBastionProps struct {
	ClusterId            string
	EksCluster           awseks.CfnCluster
	ClusterSecurityGroup awsec2.SecurityGroup
	Vpc                  awsec2.Vpc
	PrivateSubnets       *[]awsec2.ISubnet
	ContainerImage       string
}

// NewMcBastion creates bastion ECS cluster, task definitions, IAM, and cleanup Lambda.
// Equivalent to terraform/modules/bastion (~836 lines of HCL).
//
// The TF module uses null_resource with a destroy-time local-exec provisioner
// to stop ECS tasks on teardown. CDK uses a Custom Resource with a Lambda
// handler — same concept, but CDK's Provider framework handles the
// cfnresponse boilerplate automatically.
func NewMcBastion(scope constructs.Construct, id string, props *McBastionProps) {
	c := constructs.NewConstruct(scope, jsii.String(id))
	name := props.ClusterId

	// KMS + Log Group
	logsKey := awskms.NewKey(c, jsii.String("LogsKey"), &awskms.KeyProps{
		Description:       jsii.String(fmt.Sprintf("KMS key for %s bastion CloudWatch logs", name)),
		EnableKeyRotation: jsii.Bool(true),
		Alias:             jsii.String(fmt.Sprintf("alias/%s-bastion-logs", name)),
	})
	logGroup := awslogs.NewLogGroup(c, jsii.String("LogGroup"), &awslogs.LogGroupProps{
		LogGroupName:  jsii.String(fmt.Sprintf("/ecs/%s-bastion", name)),
		Retention:     awslogs.RetentionDays_ONE_YEAR,
		EncryptionKey: logsKey,
	})

	// Security group
	bastionSG := awsec2.NewSecurityGroup(c, jsii.String("BastionSG"), &awsec2.SecurityGroupProps{
		Vpc:               props.Vpc,
		SecurityGroupName: jsii.String(fmt.Sprintf("%s-bastion", name)),
		Description:       jsii.String("Bastion SG"),
	})
	props.ClusterSecurityGroup.AddIngressRule(bastionSG, awsec2.Port_Tcp(jsii.Number(443)),
		jsii.String("HTTPS from bastion"), nil)

	// ECS Cluster with ECS Exec logging
	ecsCluster := awsecs.NewCluster(c, jsii.String("Cluster"), &awsecs.ClusterProps{
		ClusterName:       jsii.String(fmt.Sprintf("%s-bastion", name)),
		ContainerInsights: jsii.Bool(true),
		Vpc:               props.Vpc,
		ExecuteCommandConfiguration: &awsecs.ExecuteCommandConfiguration{
			Logging: awsecs.ExecuteCommandLogging_OVERRIDE,
			LogConfiguration: &awsecs.ExecuteCommandLogConfiguration{
				CloudWatchLogGroup: logGroup,
			},
		},
	})

	clusterArn := fmt.Sprintf("arn:%s:eks:%s:%s:cluster/%s",
		*awscdk.Aws_PARTITION(), *awscdk.Aws_REGION(), *awscdk.Aws_ACCOUNT_ID(),
		*props.EksCluster.Name())

	// Helper: create a role + EKS access entry
	makeTaskRole := func(suffix string, policyArn string) awsiam.Role {
		role := awsiam.NewRole(c, jsii.String(fmt.Sprintf("%sRole", suffix)), &awsiam.RoleProps{
			RoleName:  jsii.String(fmt.Sprintf("%s-%s", name, suffix)),
			AssumedBy: awsiam.NewServicePrincipal(jsii.String("ecs-tasks.amazonaws.com"), nil),
		})
		role.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
			Actions:   jsii.Strings("eks:DescribeCluster", "eks:ListClusters", "eks:AccessKubernetesApi"),
			Resources: jsii.Strings(clusterArn),
		}))
		awseks.NewCfnAccessEntry(c, jsii.String(fmt.Sprintf("%sAccess", suffix)), &awseks.CfnAccessEntryProps{
			ClusterName:  props.EksCluster.Name(),
			PrincipalArn: role.RoleArn(),
			Type:         jsii.String("STANDARD"),
			AccessPolicies: &[]*awseks.CfnAccessEntry_AccessPolicyProperty{{
				PolicyArn: jsii.String(policyArn),
				AccessScope: &awseks.CfnAccessEntry_AccessScopeProperty{
					Type: jsii.String("cluster"),
				},
			}},
		})
		return role
	}

	// Bastion task role (cluster admin + SSM exec)
	bastionRole := makeTaskRole("bastion-task",
		"arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy")
	bastionRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions: jsii.Strings(
			"ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
			"ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"),
		Resources: jsii.Strings("*"),
	}))
	bastionRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions:   jsii.Strings("logs:CreateLogStream", "logs:PutLogEvents"),
		Resources: jsii.Strings(*logGroup.LogGroupArn()),
	}))

	// Log collector task role (admin view + S3 upload)
	logCollectorRole := makeTaskRole("log-collector",
		"arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy")
	logCollectorRole.AddToPolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions:   jsii.Strings("s3:PutObject"),
		Resources: jsii.Strings(fmt.Sprintf("arn:%s:s3:::%s-logs/*", *awscdk.Aws_PARTITION(), name)),
	}))

	// Bastion task definition
	bastionDef := awsecs.NewFargateTaskDefinition(c, jsii.String("BastionTaskDef"), &awsecs.FargateTaskDefinitionProps{
		Family:         jsii.String(fmt.Sprintf("%s-bastion", name)),
		Cpu:            jsii.Number(256),
		MemoryLimitMiB: jsii.Number(512),
		TaskRole:       bastionRole,
	})
	bastionDef.AddContainer(jsii.String("jumphost"), &awsecs.ContainerDefinitionOptions{
		Image:     awsecs.ContainerImage_FromRegistry(jsii.String(props.ContainerImage), nil),
		Command:   jsii.Strings("sleep", "infinity"),
		Essential: jsii.Bool(true),
		Environment: &map[string]*string{
			"CLUSTER_NAME":     props.EksCluster.Name(),
			"CLUSTER_ENDPOINT": props.EksCluster.AttrEndpoint(),
			"AWS_REGION":       awscdk.Aws_REGION(),
		},
		Logging: awsecs.LogDriver_AwsLogs(&awsecs.AwsLogDriverProps{
			LogGroup:     logGroup,
			StreamPrefix: jsii.String("bastion"),
		}),
		LinuxParameters: awsecs.NewLinuxParameters(c, jsii.String("LinuxParams"), &awsecs.LinuxParametersProps{
			InitProcessEnabled: jsii.Bool(true),
		}),
	})

	// Log collector task definition
	logCollectorDef := awsecs.NewFargateTaskDefinition(c, jsii.String("LogCollectorTaskDef"), &awsecs.FargateTaskDefinitionProps{
		Family:         jsii.String(fmt.Sprintf("%s-log-collector", name)),
		Cpu:            jsii.Number(256),
		MemoryLimitMiB: jsii.Number(512),
		TaskRole:       logCollectorRole,
	})
	logCollectorDef.AddContainer(jsii.String("log-collector"), &awsecs.ContainerDefinitionOptions{
		Image:     awsecs.ContainerImage_FromRegistry(jsii.String(props.ContainerImage), nil),
		Command:   jsii.Strings("/bin/bash", "-c", "/scripts/collect-logs.sh"),
		Essential: jsii.Bool(true),
		Environment: &map[string]*string{
			"CLUSTER_NAME": props.EksCluster.Name(),
			"AWS_REGION":   awscdk.Aws_REGION(),
		},
		Logging: awsecs.LogDriver_AwsLogs(&awsecs.AwsLogDriverProps{
			LogGroup:     logGroup,
			StreamPrefix: jsii.String("log-collector"),
		}),
	})

	// =========================================================================
	// Custom Resource: stop bastion ECS tasks on stack deletion.
	//
	// TF does this in one line:
	//   provisioner "local-exec" { when = destroy; command = "aws ecs ..." }
	//
	// CDK needs a Lambda, but the Provider framework handles cfn-response
	// automatically — cleaner than raw CF YAML Custom Resources.
	// =========================================================================

	stopTasksFn := awslambda.NewFunction(c, jsii.String("StopTasksFn"), &awslambda.FunctionProps{
		FunctionName: jsii.String(fmt.Sprintf("%s-bastion-stop-tasks", name)),
		Runtime:      awslambda.Runtime_PYTHON_3_12(),
		Handler:      jsii.String("index.handler"),
		Timeout:      awscdk.Duration_Seconds(jsii.Number(60)),
		Code: awslambda.Code_FromInline(jsii.String(`
import boto3
def handler(event, context):
    if event.get("RequestType") == "Delete":
        ecs = boto3.client("ecs")
        cluster = event["ResourceProperties"]["EcsClusterName"]
        try:
            for arn in ecs.list_tasks(cluster=cluster).get("taskArns", []):
                ecs.stop_task(cluster=cluster, task=arn, reason="Stack deletion")
        except Exception as e:
            print(f"Error: {e}")
    return {"Status": "SUCCESS"}
`)),
	})
	stopTasksFn.AddToRolePolicy(awsiam.NewPolicyStatement(&awsiam.PolicyStatementProps{
		Actions:   jsii.Strings("ecs:ListTasks", "ecs:StopTask"),
		Resources: jsii.Strings("*"),
		Conditions: &map[string]interface{}{
			"ArnEquals": map[string]*string{"ecs:cluster": ecsCluster.ClusterArn()},
		},
	}))

	customresources.NewProvider(c, jsii.String("StopTasksProvider"), &customresources.ProviderProps{
		OnEventHandler: stopTasksFn,
	})
	awscdk.NewCustomResource(c, jsii.String("StopTasksOnDelete"), &awscdk.CustomResourceProps{
		ServiceToken: stopTasksFn.FunctionArn(),
		Properties: &map[string]interface{}{
			"EcsClusterName": ecsCluster.ClusterName(),
		},
	})

	_ = bastionSG
}
