package main

import (
	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

type ManagementClusterStackProps struct {
	awscdk.StackProps

	ManagementId        string
	Environment         string
	ContainerImage      string
	RepositoryUrl       string
	RepositoryBranch    string
	RegionalAwsAccountId string
	ClusterVersion      string

	// Feature flags
	EnableBastion bool

	// Cross-account references (RC)
	DnsZoneOperatorRoleArn string
	ZoaOutputsBucketArn    string
	ZoaKmsKeyArn           string

	// OIDC (RC-generated values)
	OidcBucketName       string
	OidcBucketArn        string
	OidcBucketRegion     string
	OidcWriterRoleArn    string
	OidcCloudfrontDomain string
}

func NewManagementClusterStack(scope constructs.Construct, id string, props *ManagementClusterStackProps) awscdk.Stack {
	stack := awscdk.NewStack(scope, jsii.String(id), &props.StackProps)

	// VPC
	vpc := NewMcVpc(stack, "Vpc", &McVpcProps{
		ResourceNameBase: props.ManagementId,
	})

	// EKS Cluster
	eks := NewMcEksCluster(stack, "EksCluster", &McEksClusterProps{
		ClusterId:             props.ManagementId,
		ClusterVersion:        props.ClusterVersion,
		Vpc:                   vpc.Vpc,
		PrivateSubnets:        vpc.PrivateSubnets,
		ClusterSecurityGroup:  vpc.ClusterSecurityGroup,
	})

	// ECS Bootstrap
	NewMcEcsBootstrap(stack, "EcsBootstrap", &McEcsBootstrapProps{
		ClusterId:            props.ManagementId,
		Vpc:                  vpc.Vpc,
		PrivateSubnets:       vpc.PrivateSubnets,
		EksCluster:           eks.Cluster,
		ClusterSecurityGroup: vpc.ClusterSecurityGroup,
		ContainerImage:       props.ContainerImage,
		RcAwsAccountId:       props.RegionalAwsAccountId,
		RepositoryUrl:        props.RepositoryUrl,
		RepositoryBranch:     props.RepositoryBranch,
	})

	// Bastion (conditional)
	if props.EnableBastion {
		NewMcBastion(stack, "Bastion", &McBastionProps{
			ClusterId:            props.ManagementId,
			EksCluster:           eks.Cluster,
			ClusterSecurityGroup: vpc.ClusterSecurityGroup,
			Vpc:                  vpc.Vpc,
			PrivateSubnets:       vpc.PrivateSubnets,
			ContainerImage:       props.ContainerImage,
		})
	}

	// Pod Identities — one construct per TF module
	clusterName := eks.Cluster.ClusterName()

	NewDnsPodIdentity(stack, "DnsPodIdentity", &DnsPodIdentityProps{
		ManagementId:           props.ManagementId,
		EksClusterName:         clusterName,
		DnsZoneOperatorRoleArn: props.DnsZoneOperatorRoleArn,
	})

	NewHypershiftOidc(stack, "HypershiftOidc", &HypershiftOidcProps{
		ManagementId:       props.ManagementId,
		EksClusterName:     clusterName,
		OidcBucketName:     props.OidcBucketName,
		OidcBucketRegion:   props.OidcBucketRegion,
		OidcWriterRoleArn:  props.OidcWriterRoleArn,
		OidcCloudfrontDomain: props.OidcCloudfrontDomain,
	})

	NewPrometheusRemoteWrite(stack, "PrometheusRemoteWrite", &PrometheusRemoteWriteProps{
		ManagementId:        props.ManagementId,
		EksClusterName:      clusterName,
		RegionalAwsAccountId: props.RegionalAwsAccountId,
	})

	NewLokiLogForwarder(stack, "LokiLogForwarder", &LokiLogForwarderProps{
		ManagementId:        props.ManagementId,
		EksClusterName:      clusterName,
		RegionalAwsAccountId: props.RegionalAwsAccountId,
	})

	NewCloudWatchExporter(stack, "CloudWatchExporter", &CloudWatchExporterProps{
		ManagementId:   props.ManagementId,
		EksClusterName: clusterName,
	})

	NewKubeApplier(stack, "KubeApplier", &KubeApplierProps{
		ManagementId:   props.ManagementId,
		EksClusterName: clusterName,
		RcAwsAccountId: props.RegionalAwsAccountId,
	})

	if props.ZoaOutputsBucketArn != "" {
		NewZoaJobPodIdentity(stack, "ZoaJobPodIdentity", &ZoaJobPodIdentityProps{
			ManagementId:       props.ManagementId,
			EksClusterName:     clusterName,
			ZoaOutputsBucketArn: props.ZoaOutputsBucketArn,
			ZoaKmsKeyArn:       props.ZoaKmsKeyArn,
		})
	}

	NewGrafanaCloudWatchLogs(stack, "GrafanaCloudWatchLogs", &GrafanaCloudWatchLogsProps{
		RegionalId:          props.ManagementId,
		GrafanaRoleAccountId: props.RegionalAwsAccountId,
	})

	return stack
}

func main() {
	defer jsii.Close()
	app := awscdk.NewApp(nil)

	NewManagementClusterStack(app, "mc01", &ManagementClusterStackProps{
		StackProps: awscdk.StackProps{
			Env: &awscdk.Environment{
				Region: jsii.String("us-east-1"),
			},
		},
		ManagementId:        "mc01",
		Environment:         "integration",
		ContainerImage:      "public.ecr.aws/example/platform:latest",
		RepositoryUrl:       "https://github.com/org/rosa-hyperfleet",
		RepositoryBranch:    "main",
		RegionalAwsAccountId: "123456789012",
		ClusterVersion:      "1.34",
		EnableBastion:       true,
	})

	app.Synth(nil)
}
