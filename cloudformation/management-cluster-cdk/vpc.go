package main

import (
	"fmt"

	"github.com/aws/aws-cdk-go/awscdk/v2/awsec2"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

type McVpcProps struct {
	ResourceNameBase string
}

type McVpcOutputs struct {
	Vpc                  awsec2.Vpc
	PrivateSubnets       *[]awsec2.ISubnet
	ClusterSecurityGroup awsec2.SecurityGroup
	VpcEndpointsSG       awsec2.SecurityGroup
}

// NewMcVpc creates the VPC, subnets, NAT gateways, VPC endpoints, and security groups.
// Equivalent to terraform/modules/vpc (~342 lines of HCL).
//
// CDK's L2 Vpc construct creates subnets, route tables, NAT gateways, and IGW
// in one call — replacing ~35 individual CF/TF resources.
func NewMcVpc(scope constructs.Construct, id string, props *McVpcProps) *McVpcOutputs {
	c := constructs.NewConstruct(scope, jsii.String(id))
	name := props.ResourceNameBase

	vpc := awsec2.NewVpc(c, jsii.String("Vpc"), &awsec2.VpcProps{
		VpcName:              jsii.String(fmt.Sprintf("%s-vpc", name)),
		IpAddresses:          awsec2.IpAddresses_Cidr(jsii.String("10.0.0.0/16")),
		MaxAzs:               jsii.Number(3),
		NatGateways:          jsii.Number(3), // One per AZ for HA (FedRAMP)
		SubnetConfiguration: &[]*awsec2.SubnetConfiguration{
			{
				Name:       jsii.String("private"),
				SubnetType: awsec2.SubnetType_PRIVATE_WITH_EGRESS,
				CidrMask:   jsii.Number(18),
			},
			{
				Name:       jsii.String("public"),
				SubnetType: awsec2.SubnetType_PUBLIC,
				CidrMask:   jsii.Number(22),
			},
		},
	})

	// Tag private subnets for EKS
	for _, subnet := range *vpc.PrivateSubnets() {
		awscdk.Tags_Of(subnet).Add(
			jsii.String(fmt.Sprintf("kubernetes.io/cluster/%s", name)),
			jsii.String("owned"), nil,
		)
		awscdk.Tags_Of(subnet).Add(
			jsii.String("kubernetes.io/role/internal-elb"),
			jsii.String("1"), nil,
		)
	}

	// EKS cluster security group
	clusterSG := awsec2.NewSecurityGroup(c, jsii.String("EksClusterSG"), &awsec2.SecurityGroupProps{
		Vpc:               vpc,
		SecurityGroupName: jsii.String(fmt.Sprintf("%s-eks-cluster", name)),
		Description:       jsii.String("EKS cluster security group"),
		AllowAllOutbound:  jsii.Bool(false),
	})
	clusterSG.AddIngressRule(awsec2.Peer_Ipv4(vpc.VpcCidrBlock()), awsec2.Port_Tcp(jsii.Number(443)),
		jsii.String("HTTPS from VPC"), nil)
	clusterSG.AddEgressRule(awsec2.Peer_AnyIpv4(), awsec2.Port_Tcp(jsii.Number(443)),
		jsii.String("HTTPS to container registries"), nil)
	clusterSG.AddEgressRule(awsec2.Peer_Ipv4(vpc.VpcCidrBlock()), awsec2.Port_AllTraffic(),
		jsii.String("All traffic within VPC"), nil)

	// VPC endpoints security group
	vpcesg := awsec2.NewSecurityGroup(c, jsii.String("VpcEndpointsSG"), &awsec2.SecurityGroupProps{
		Vpc:               vpc,
		SecurityGroupName: jsii.String(fmt.Sprintf("%s-vpc-endpoints", name)),
		Description:       jsii.String("VPC endpoints security group"),
	})
	vpcesg.AddIngressRule(awsec2.Peer_Ipv4(vpc.VpcCidrBlock()), awsec2.Port_Tcp(jsii.Number(443)),
		jsii.String("HTTPS from VPC"), nil)

	// S3 gateway endpoint
	vpc.AddGatewayEndpoint(jsii.String("S3Endpoint"), &awsec2.GatewayVpcEndpointOptions{
		Service: awsec2.GatewayVpcEndpointAwsService_S3(),
	})

	// Interface endpoints
	for _, svc := range []awsec2.InterfaceVpcEndpointAwsService{
		awsec2.InterfaceVpcEndpointAwsService_ECR(),
		awsec2.InterfaceVpcEndpointAwsService_ECR_DOCKER(),
		awsec2.InterfaceVpcEndpointAwsService_STS(),
		awsec2.InterfaceVpcEndpointAwsService_CLOUDWATCH_LOGS(),
		awsec2.InterfaceVpcEndpointAwsService_EC2(),
	} {
		vpc.AddInterfaceEndpoint(svc.Name(), &awsec2.InterfaceVpcEndpointOptions{
			Service:           svc,
			PrivateDnsEnabled: jsii.Bool(true),
			SecurityGroups:    &[]awsec2.ISecurityGroup{vpcesg},
		})
	}

	return &McVpcOutputs{
		Vpc:                  vpc,
		PrivateSubnets:       vpc.PrivateSubnets(),
		ClusterSecurityGroup: clusterSG,
		VpcEndpointsSG:       vpcesg,
	}
}
