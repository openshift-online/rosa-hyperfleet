# Design Decision 002: MQTT-Based Resource Distribution via Maestro

## Status

**Implemented**

## Table of Contents

1. [Scope](#scope)
2. [Context](#context)
3. [Alternatives Explored](#alternatives-explored)
   - [Alternative 1: Direct REST API Push](#alternative-1-direct-rest-api-push)
   - [Alternative 2: Pull-Based with Polling](#alternative-2-pull-based-with-polling)
   - [Alternative 3: Message Queue with AWS Services](#alternative-3-message-queue-with-aws-services)
4. [Decision: Maestro with AWS IoT Core MQTT](#decision-maestro-with-aws-iot-core-mqtt)
5. [High-Level Architecture](#high-level-architecture)
6. [Complete Message Flow](#complete-message-flow)
7. [MQTT Topic Structure](#mqtt-topic-structure)
8. [Implementation Design](#implementation-design)
   - [Maestro Server](#maestro-server-regional-cluster)
   - [Maestro Agent](#maestro-agent-management-cluster)
   - [Authentication & Security](#authentication--security)
     - [IAM Roles and Cross-Account Setup](#iam-roles-and-cross-account-setup)
     - [IAM Trust Relationships](#iam-trust-relationships)
     - [Secret Flow Architecture](#secret-flow-architecture)
     - [Key IAM Components](#key-iam-components)
   - [State Management](#state-management)
9. [Deployment Workflow](#deployment-workflow)
10. [Certificate Transfer Process](#certificate-transfer-process)
11. [Network Topology](#network-topology)
12. [Benefits](#benefits)
13. [Operational Considerations](#operational-considerations)
    - [Monitoring & Alerting](#monitoring--alerting)
    - [Troubleshooting Guide](#troubleshooting-guide)
    - [Performance Tuning](#performance-tuning)
    - [Cost Optimization](#cost-optimization)
14. [Related Documentation](#related-documentation)

---

## Scope

This design decision addresses how the Regional Cluster distributes cluster configuration and resources to Management Clusters without direct network connectivity between their Kubernetes APIs.

The solution must work in an environment where Management Clusters have fully private Kubernetes APIs with no network path to the Regional Cluster, enabling maximum security isolation while maintaining operational capability. This document provides comprehensive architecture diagrams, detailed implementation guidance, and operational procedures for the Maestro MQTT-based orchestration system in the ROSA Regional Platform.

## Context

The rosa-regional-platform requires a mechanism to distribute HostedCluster and NodePool resources from the Regional Cluster's CLM (Cluster Lifecycle Manager) to multiple Management Clusters across potentially different AWS accounts.

**Critical Constraint**: Management Clusters MUST have no network path to the Regional Cluster Kubernetes API, and vice versa. This eliminates traditional push mechanisms that rely on direct API access.

This constraint arises from fundamental security requirements:

- **Network Isolation**: No VPC peering, Transit Gateway, or VPN connections between Regional and Management VPCs
- **Account Separation**: Management Clusters may reside in different AWS accounts with independent governance
- **Zero Trust Architecture**: No implicit trust relationships based on network topology
- **Attack Surface Minimization**: Eliminating direct API exposure reduces potential security vulnerabilities

## Alternatives Explored

### Alternative 1: Direct REST API Push

**Approach**: Regional Cluster makes HTTPS requests to Management Cluster API endpoints

- Regional Cluster CLM directly calls Management Cluster Kubernetes APIs
- VPC Peering or Transit Gateway for network connectivity
- API Gateway or PrivateLink for secure exposure

**Assessment**: Violates fundamental security requirement of network isolation. Creates operational coupling and increases attack surface. Requires complex network topology management.

### Alternative 2: Pull-Based with Polling

**Approach**: Management Clusters poll Regional Cluster for updates

- Management Clusters periodically query Regional API for resource changes
- Time-based reconciliation loop (e.g., every 30 seconds)
- Regional API exposed via PrivateLink or VPC Peering

**Assessment**: Still requires network connectivity. Introduces latency (bounded by poll interval), increases API load, and creates inefficient resource utilization. Not event-driven, leading to delayed propagation.

### Alternative 3: Message Queue with AWS Services

**Implementation Options**:

- **Amazon SQS/SNS**: Queue-based message delivery with topic subscriptions
- **Amazon EventBridge**: Event bus for cross-account event routing
- **AWS IoT Core MQTT**: Publish-subscribe messaging with certificate-based authentication

**Assessment**: Viable approach that satisfies network isolation requirement. Each has different trade-offs in terms of message delivery semantics, authentication models, and operational complexity.

## Decision: Maestro with AWS IoT Core MQTT

**Chosen Approach**: Alternative 3 (Message Queue) implemented via **Maestro** orchestration system using **AWS IoT Core MQTT** as the transport layer.

**Implementation Rationale**:

- **Network Isolation**: AWS IoT Core is an internet-accessible service, eliminating need for VPC connectivity between Regional and Management clusters
- **Cross-Account Support**: IoT Core supports cross-account authentication via IAM policies, enabling Management Clusters in different AWS accounts to connect to Regional account IoT endpoint
- **Message Delivery Guarantees**: MQTT QoS 1 (at least once delivery) ensures reliable resource distribution
- **Event-Driven Architecture**: Immediate message delivery upon publication, enabling low-latency cluster operations
- **Proven Technology**: Maestro is used in production by ARO-HCP (Azure Red Hat OpenShift - Hosted Control Planes)

**Trade-offs**: Introduces dependency on AWS IoT Core availability and requires MQTT expertise for troubleshooting. Certificate management adds operational complexity (manual transfer process).

## High-Level Architecture

The following diagram shows all AWS components and their relationships across Regional and Management clusters, providing a complete view of the distributed system topology.

```mermaid
graph TB
    subgraph Regional["Regional AWS Account (123456789012)"]
        subgraph RegVPC["VPC: 10.0.0.0/16"]
            subgraph RegEKS["EKS Cluster: regional"]
                Server["Maestro Server<br/>───────────<br/>Replicas: 2<br/>Ports: 8080(HTTP), 8090(gRPC)<br/>ServiceAccount: maestro-server"]
                ASCP_S["AWS Secrets Store<br/>CSI Driver<br/>Mount: /mnt/secrets-store"]

                Server -->|Mounts| ASCP_S
            end

            subgraph DBSubnet["Private Subnets (Multi-AZ)"]
                RDS["RDS PostgreSQL 16.4<br/>───────────<br/>Instance: db.t4g.micro<br/>Storage: 20GB (encrypted)<br/>Backups: 7 days"]
            end

            SG_DB["Security Group<br/>Port 5432<br/>Source: EKS cluster only"]
        end

        IoT["AWS IoT Core<br/>───────────<br/>Endpoint: *.iot.us-east-1.amazonaws.com:8883<br/>Auth: X.509 Certificates<br/>Protocol: MQTT TLS"]

        subgraph SM_Reg["AWS Secrets Manager"]
            SM_Server["regional-maestro-server-cert<br/>(cert + key)"]
            SM_DB["regional-maestro-db-credentials<br/>(host, port, user, pass)"]
            SM_Consumers["regional-maestro-consumers<br/>(pre-provisioned metadata)"]
        end

        IAM_Server["IAM Role<br/>regional-maestro-server<br/>───────────<br/>Permissions:<br/>• IoT: Connect, Publish, Subscribe<br/>• RDS: Connect<br/>• Secrets: GetSecretValue"]

        Server -->|Pod Identity| IAM_Server
        IAM_Server -->|Read| SM_Server
        IAM_Server -->|Read| SM_DB
        IAM_Server -->|Read| SM_Consumers
        ASCP_S -.->|Mounts as files| SM_Server
        ASCP_S -.->|Mounts as files| SM_DB
        Server -->|Port 5432<br/>SSL/TLS| SG_DB
        SG_DB -->|Access| RDS
        Server -->|MQTT<br/>Port 8883| IoT
    end

    subgraph Mgmt1["Management AWS Account (987654321098)"]
        subgraph MgmtVPC1["VPC: 10.1.0.0/16"]
            subgraph MgmtEKS1["EKS Cluster: mc01"]
                Agent1["Maestro Agent<br/>───────────<br/>Replicas: 1<br/>Consumer: mc01<br/>ServiceAccount: maestro-agent"]
                ASCP_A1["AWS Secrets Store<br/>CSI Driver<br/>Mount: /mnt/secrets-store"]

                Agent1 -->|Mounts| ASCP_A1
            end
        end

        SM_Agent1["AWS Secrets Manager<br/>mc01-maestro-agent-cert<br/>(manually created)"]

        IAM_Agent1["IAM Role<br/>mc01-maestro-agent<br/>───────────<br/>Permissions:<br/>• IoT: Connect to Regional IoT (cross-account)<br/>• Secrets: GetSecretValue (local)<br/>Trust: pods.eks.amazonaws.com (same account)"]

        Agent1 -->|Pod Identity<br/>Same Account| IAM_Agent1
        IAM_Agent1 -->|Read<br/>Local Secret| SM_Agent1
        ASCP_A1 -.->|Mounts as files| SM_Agent1
        Agent1 -.->|MQTT<br/>Port 8883<br/>Cross-Account IAM| IoT
    end

    subgraph Mgmt2["Management AWS Account (234567890123)"]
        subgraph MgmtVPC2["VPC: 10.2.0.0/16"]
            subgraph MgmtEKS2["EKS Cluster: mc02"]
                Agent2["Maestro Agent<br/>───────────<br/>Replicas: 1<br/>Consumer: mc02<br/>ServiceAccount: maestro-agent"]
                ASCP_A2["AWS Secrets Store<br/>CSI Driver"]

                Agent2 -->|Mounts| ASCP_A2
            end
        end

        SM_Agent2["AWS Secrets Manager<br/>mc02-maestro-agent-cert<br/>(manually created)"]

        IAM_Agent2["IAM Role<br/>mc02-maestro-agent<br/>───────────<br/>Trust: pods.eks.amazonaws.com (same account)"]

        Agent2 -->|Pod Identity<br/>Same Account| IAM_Agent2
        IAM_Agent2 -->|Read<br/>Local Secret| SM_Agent2
        ASCP_A2 -.->|Mounts as files| SM_Agent2
        Agent2 -.->|MQTT<br/>Port 8883<br/>Cross-Account IAM| IoT
    end

    style Server fill:#e1f5ff,stroke:#0066cc,stroke-width:2px
    style Agent1 fill:#ffe1e1,stroke:#cc0000,stroke-width:2px
    style Agent2 fill:#ffe1e1,stroke:#cc0000,stroke-width:2px
    style IoT fill:#d4edda,stroke:#28a745,stroke-width:3px
    style RDS fill:#e8e8ff,stroke:#6666ff,stroke-width:2px
    style SM_Server fill:#fff3cd,stroke:#ffc107,stroke-width:2px
    style SM_DB fill:#fff3cd,stroke:#ffc107,stroke-width:2px
    style IAM_Server fill:#cce5ff
    style IAM_Agent1 fill:#ffcccc
    style IAM_Agent2 fill:#ffcccc
```

**Key Architectural Points:**

- **Regional Cluster**: Centralized Maestro Server with RDS state database
- **Management Clusters**: Distributed agents in separate AWS accounts
- **AWS IoT Core**: MQTT broker enabling pub/sub communication (cross-account via IAM permissions)
- **Same-Account Pod Identity**: Each cluster uses Pod Identity with roles in their own account
- **Local Secrets**: Each cluster reads MQTT certificates from its own Secrets Manager
- **Network Isolation**: No direct network path between regional and management clusters

## Complete Message Flow

The following sequence diagram illustrates the end-to-end flow showing how ManifestWork resources are distributed from Regional to Management clusters, including initialization, resource creation, and status reporting.

```mermaid
sequenceDiagram
    participant User as Platform Operator
    participant API as Regional Cluster<br/>Maestro HTTP API
    participant Server as Maestro Server<br/>(Regional)
    participant DB as RDS PostgreSQL<br/>(Regional)
    participant SM as Secrets Manager<br/>(Regional)
    participant IoT as AWS IoT Core<br/>MQTT Broker
    participant Agent as Maestro Agent<br/>(Management)
    participant K8s as Management Cluster<br/>Kubernetes API

    Note over User,K8s: Initialization Phase
    Server->>SM: Read server MQTT cert via ASCP (local)
    Server->>DB: Initialize schema, load consumers
    Server->>IoT: Connect with X.509 cert
    Note over Agent: Agent reads from Management account Secrets Manager
    Agent->>Agent: Read agent MQTT cert via ASCP (local)
    Agent->>IoT: Connect with X.509 cert (cross-account via IAM)
    Agent->>IoT: Subscribe to topic:<br/>sources/{regional_id}/consumers/mc01/sourceevents

    Note over User,K8s: ManifestWork Creation
    User->>API: POST /api/maestro/v1/resources<br/>ManifestWork manifest
    API->>Server: Create ManifestWork
    Server->>DB: Store ManifestWork (status: pending)
    DB-->>Server: Stored (ID: abc123)
    Server->>Server: Wrap in CloudEvent envelope
    Server->>IoT: Publish to topic:<br/>sources/{regional_id}/consumers/mc01/sourceevents

    Note over User,K8s: Message Delivery
    IoT->>Agent: Deliver MQTT message
    Agent->>Agent: Parse CloudEvent
    Agent->>Agent: Extract ManifestWork payload
    Agent->>K8s: Apply Kubernetes resources<br/>(Deployment, Service, etc.)
    K8s-->>Agent: Resources created
    Agent->>Agent: Create AppliedManifestWork<br/>(status: Applied)

    Note over User,K8s: Status Reporting
    Agent->>Agent: Wrap status in CloudEvent
    Agent->>IoT: Publish to topic:<br/>sources/{regional_id}/consumers/mc01/agentevents
    IoT->>Server: Deliver status message
    Server->>Server: Parse status CloudEvent
    Server->>DB: Update ManifestWork<br/>(status: Applied)

    Note over User,K8s: Status Query
    User->>API: GET /api/maestro/v1/resources/abc123
    API->>Server: Get ManifestWork status
    Server->>DB: Query status
    DB-->>Server: status: Applied
    Server-->>API: Return status
    API-->>User: HTTP 200 OK<br/>status: Applied

    Note over User,K8s: Health Monitoring
    Agent->>K8s: Watch applied resources
    K8s-->>Agent: Resource health events
    Agent->>IoT: Publish status updates<br/>(periodic heartbeat)
    IoT->>Server: Deliver updates
    Server->>DB: Update resource status
```

**Message Flow Steps:**

1. **Initialization**: Server and agents connect to IoT Core with X.509 certificates
2. **Subscription**: Agents subscribe to their consumer-specific topics
3. **Publication**: Server publishes ManifestWork wrapped in CloudEvent to agent topic
4. **Application**: Agent receives, parses, and applies Kubernetes resources
5. **Status Update**: Agent reports status back through separate MQTT topic
6. **Persistence**: Server stores all state in RDS for API queries

## MQTT Topic Structure

The hierarchical topic organization provides consumer isolation and message routing. Each Management Cluster has dedicated topics that enforce strict authorization boundaries.

The topic root is scoped by `{regional_id}` — the identifier of the Regional Cluster. This ensures topic namespaces are fully isolated across environments (e.g., ephemeral, integration, production), so multiple Regional Clusters sharing the same AWS IoT Core endpoint cannot interfere with each other's message flows.

```mermaid
graph TB
    Root["MQTT Topic Root<br/>sources/{regional_id}/consumers"]

    Root --> C1["/{consumer-name-1}"]
    Root --> C2["/{consumer-name-2}"]
    Root --> CN["/{consumer-name-N}"]

    C1 --> SE1["sourceevents<br/>───────────<br/>Direction: Server → Agent<br/>Publisher: Maestro Server<br/>Subscriber: Maestro Agent<br/>QoS: 1 (at least once)<br/>Payload: CloudEvent + ManifestWork"]

    C1 --> AE1["agentevents<br/>───────────<br/>Direction: Agent → Server<br/>Publisher: Maestro Agent<br/>Subscriber: Maestro Server<br/>QoS: 1 (at least once)<br/>Payload: CloudEvent + Status"]

    C2 --> SE2["sourceevents"]
    C2 --> AE2["agentevents"]

    CN --> SEN["sourceevents"]
    CN --> AEN["agentevents"]

    style Root fill:#d4edda,stroke:#28a745,stroke-width:3px
    style SE1 fill:#e1f5ff,stroke:#0066cc,stroke-width:2px
    style AE1 fill:#ffe1e1,stroke:#cc0000,stroke-width:2px
    style SE2 fill:#e1f5ff,stroke:#0066cc,stroke-width:2px
    style AE2 fill:#ffe1e1,stroke:#cc0000,stroke-width:2px
    style SEN fill:#e1f5ff,stroke:#0066cc,stroke-width:2px
    style AEN fill:#ffe1e1,stroke:#cc0000,stroke-width:2px
```

**Topic Examples:**

- **Server publishes to**: `sources/{regional_id}/consumers/mc01/sourceevents`
- **Agent subscribes to**: `sources/{regional_id}/consumers/mc01/sourceevents`
- **Agent publishes to**: `sources/{regional_id}/consumers/mc01/agentevents`
- **Server subscribes to**: `sources/{regional_id}/consumers/+/agentevents` (wildcard)

**Topic Security Model:**

- Each agent has IoT Policy allowing subscribe/receive ONLY on its consumer-specific topic
- Server has IoT Policy allowing publish to all `sourceevents` topics within its `{regional_id}` namespace
- Topic isolation ensures multi-tenant security — agents cannot intercept messages for other clusters
- Wildcard subscriptions (`+`) are restricted to the Maestro Server role only
- Environment isolation — the `{regional_id}` prefix prevents cross-environment message leakage when multiple environments (e.g., ephemeral, integration) share the same AWS IoT Core endpoint
- Client IDs for the Maestro Server are set to the pod name, preventing connection collisions across replicas

## Implementation Design

### Maestro Server (Regional Cluster)

- Runs in Regional Cluster with HTTP (8080) and gRPC (8090) APIs
- Connects to AWS IoT Core using X.509 certificate authentication; each pod uses its pod name as the MQTT client ID to avoid connection collisions across replicas
- Stores resource state in dedicated RDS PostgreSQL database
- Publishes ManifestWork resources to consumer-specific MQTT topics scoped under `sources/{regional_id}/consumers/`
- Subscribes to status update topics from all agents

### Maestro Agent (Management Cluster)

- Runs in each Management Cluster (single replica per cluster)
- Connects to Regional AWS account IoT Core via cross-account IAM permissions
- Subscribes to consumer-specific topic: `sources/{regional_id}/consumers/{cluster-id}/sourceevents`
- Applies received Kubernetes resources to local Management Cluster API
- Reports status back via: `sources/{regional_id}/consumers/{cluster-id}/agentevents`
- See [MQTT Topic Structure](#mqtt-topic-structure) section for detailed topic organization

### Authentication & Security

The authentication model leverages AWS-native mechanisms for both same-account secret access and cross-account IoT connectivity.

#### IAM Roles and Cross-Account Setup

The following diagram shows detailed IAM role configuration, Pod Identity associations, and cross-account authentication flows.

```mermaid
graph TB
    subgraph "Regional AWS Account (123456789012)"
        subgraph "Regional EKS Cluster (regional)"
            MS[Maestro Server<br/>ServiceAccount]
            ASCP_RC[AWS Secrets Store<br/>CSI Driver]

            MS -->|Pod Identity| MSRole[IAM Role:<br/>regional-maestro-server]
            MS -->|Volume Mount| ASCP_RC
        end

        subgraph "AWS Secrets Manager (Regional Account)"
            SecretDB[(Secret:<br/>regional-maestro-db-credentials)]
            SecretMQTTServer[(Secret:<br/>regional-maestro-server-cert)]
        end

        subgraph "AWS IoT Core (Regional Account)"
            IoTThing1[IoT Thing:<br/>regional-maestro-server]
            IoTThing2[IoT Thing:<br/>mc01-maestro-agent]
            IoTBroker[MQTT Broker<br/>Port 8883]

            IoTThing1 -->|publishes to| IoTBroker
            IoTThing2 -->|subscribes to| IoTBroker
        end

        RDS[(RDS PostgreSQL<br/>Maestro State)]

        MSRole -->|GetSecretValue| SecretDB
        MSRole -->|GetSecretValue| SecretMQTTServer
        ASCP_RC -->|Mounts via<br/>Pod Identity| SecretDB
        ASCP_RC -->|Mounts via<br/>Pod Identity| SecretMQTTServer
        MSRole -->|Connect| IoTBroker
        MSRole -->|Read/Write| RDS
    end

    subgraph "Management AWS Account (987654321098)"
        subgraph "Management EKS Cluster (mc01)"
            MA[Maestro Agent<br/>ServiceAccount]
            ASCP_MC[AWS Secrets Store<br/>CSI Driver]

            MA -->|Pod Identity| MARole[IAM Role:<br/>mc01-maestro-agent<br/>SAME ACCOUNT]
            MA -->|Volume Mount| ASCP_MC
        end

        subgraph "AWS Secrets Manager (Management Account)"
            SecretMQTTAgentLocal[(Secret:<br/>mc01-maestro-agent-cert<br/>Manually Created)]
        end

        MARole -->|GetSecretValue<br/>Same Account| SecretMQTTAgentLocal
        ASCP_MC -->|Mounts via<br/>Pod Identity| SecretMQTTAgentLocal
        MA -.->|Connect via MQTT Certificate<br/>Cross-Account IAM Permissions| IoTBroker
    end

    style MSRole fill:#e1f5ff
    style MARole fill:#ffe1e1
    style SecretMQTTAgentLocal fill:#fff3cd
    style IoTBroker fill:#d4edda
    style ASCP_RC fill:#e8f4f8
    style ASCP_MC fill:#e8f4f8
```

#### IAM Trust Relationships

This detailed flow shows how Pod Identity enables same-account secret access and cross-account IoT authentication.

```mermaid
sequenceDiagram
    participant MC as Management Cluster Pod<br/>(Account 987654321098)
    participant ASCP as ASCP CSI Driver
    participant STS as AWS STS
    participant SM as Secrets Manager<br/>(Account 987654321098)
    participant IoT as IoT Core<br/>(Account 123456789012)

    Note over MC,SM: Pod Identity Same-Account Flow

    MC->>ASCP: Mount secret volume
    ASCP->>STS: AssumeRole(mc01-maestro-agent)<br/>Source Account: 987654321098

    STS->>STS: Verify Pod Identity Token

    Note over STS: Trust Policy allows:<br/>- Service: pods.eks.amazonaws.com<br/>- Same Account Only

    STS-->>ASCP: Temporary credentials for role

    ASCP->>SM: GetSecretValue(mc01-maestro-agent-cert)<br/>Same Account

    Note over SM: No resource policy needed:<br/>Same-account IAM permissions apply

    SM-->>ASCP: Return secret (MQTT certificate + key)
    ASCP-->>MC: Mount secret as files

    MC->>IoT: Connect to Regional IoT Core<br/>using IAM permissions and MQTT certificate
    IoT-->>MC: Authenticated MQTT connection (cross-account via IAM)
```

#### Secret Flow Architecture

This diagram shows how secrets flow from Terraform creation through manual transfer to pod consumption.

```mermaid
graph LR
    subgraph "Regional Cluster (Regional Account)"
        TF1[Terraform] -->|Creates| IoTCerts[IoT Certificates]
        IoTCerts -->|Stores in| SM1[Secrets Manager<br/>Regional Account<br/>server-mqtt-cert]

        ASCP_RC1[ASCP CSI Driver] -->|Mounts from<br/>Same Account| SM1
        ASCP_RC1 -->|Mounts as| FilesRC[Files in Pod]

        MS1[Maestro Server] -->|Reads| FilesRC
        MS1 -->|Publishes to| MQTT[IoT Core MQTT<br/>Regional Account]
    end

    subgraph "Management Cluster (Management Account)"
        SM2[Secrets Manager<br/>Management Account<br/>agent-mqtt-cert<br/>Manually Created]

        ASCP_MC1[ASCP CSI Driver] -->|Mounts from<br/>Same Account| SM2
        ASCP_MC1 -->|Mounts as| FilesMC[Files in Pod]

        MA1[Maestro Agent] -->|Reads| FilesMC
        MA1 -.->|Subscribes to<br/>Cross-Account IAM| MQTT
    end

    TF1 -.->|Manual Transfer<br/>Certificate Data| SM2

    style SM1 fill:#fff3cd
    style SM2 fill:#fff3cd
    style ASCP_MC1 fill:#ffe1e1
    style ASCP_RC1 fill:#e8f4f8
    style MQTT fill:#d4edda
```

#### Key IAM Components

**Regional Account (123456789012)**

**IAM Role:** `regional-maestro-server`

- Access to IoT Core (connect, publish, subscribe)
- Access to RDS (connect, read, write)
- Access to Secrets Manager (GetSecretValue)
- Mounted via ASCP CSI Driver

**Resources:**

- AWS IoT Core Things, Certificates, and Policies (for server + all agents)
- AWS Secrets Manager secrets (server cert, DB credentials, consumer registrations)
- RDS PostgreSQL database
- EKS cluster running Maestro Server

**Trust Policy (Same-Account):**

```json
{
  "Statement": [
    {
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
```

**Note:** Agent certificates are created in Regional IoT Core but stored in Management account Secrets Manager via manual transfer.

**Management Account (987654321098)**

**IAM Role:** `mc01-maestro-agent`

- Created in **Management Account** (same account as cluster)
- Accesses local Secrets Manager (same-account)
- Has cross-account IoT permissions to Regional IoT Core

**Resources:**

- EKS cluster running Maestro Agent
- AWS Secrets Manager secret (manually created with transferred certificate data)
- Pod Identity association (same-account role)

**Pod Identity Association:**

```hcl
# In Management Cluster Terraform
resource "aws_eks_pod_identity_association" "maestro_agent" {
  cluster_name    = "mc01"
  namespace       = "maestro"
  service_account = "maestro-agent"
  role_arn        = "arn:aws:iam::987654321098:role/mc01-maestro-agent"
  # ↑ Role is in SAME account as management cluster
}
```

**Agent IAM Permissions:**

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:*:987654321098:secret:mc01-maestro-agent-cert*"
    },
    {
      "Effect": "Allow",
      "Action": ["iot:Connect", "iot:Subscribe", "iot:Receive", "iot:Publish"],
      "Resource": [
        "arn:aws:iot:us-east-1:123456789012:client/*",
        "arn:aws:iot:us-east-1:123456789012:topic/sources/{regional_id}/consumers/mc01/*",
        "arn:aws:iot:us-east-1:123456789012:topicfilter/sources/{regional_id}/consumers/mc01/*"
      ]
    }
  ]
}
```

**Note:** The agent reads secrets from its own account, but has IAM permissions to access IoT Core in the Regional account.

#### Authentication Flow Summary

1. **Regional Cluster (Same Account)**
   - Maestro Server uses Pod Identity → assumes regional account role (same account)
   - ASCP CSI Driver mounts secrets from regional account Secrets Manager (same account)
   - Maestro Server reads mounted files → connects to IoT Core (same account)

2. **Management Cluster (Same Account for Secrets, Cross-Account for IoT)**
   - Maestro Agent uses Pod Identity → assumes management account role (same account)
   - ASCP CSI Driver mounts secrets from management account Secrets Manager (same account)
   - Agent reads mounted certificate files → connects to Regional IoT Core (cross-account via IAM permissions)

#### Why This Design?

**Centralized Certificate Creation:**

- All IoT certificates created in one place (regional account IoT Core)
- Certificate data manually transferred to management clusters (not automated)

**Security Benefits:**

- Explicit IAM permissions for cross-account IoT access
- Secrets never in Terraform state (manual transfer process)
- Secrets never transmitted over network (mounted via CSI driver from local account)
- Least privilege access (each role has minimal permissions)
- Account sovereignty (each cluster owns its own secrets)

**Operational Simplicity:**

- No cross-account secret access policies needed
- No cross-account IAM trust policies needed
- Each cluster uses standard same-account Pod Identity
- Simple IAM permissions for IoT access (resource-based authorization)
- Clear operational boundaries between regional and management teams

### State Management

- **CLM as Source of Truth**: All cluster state authoritative in CLM RDS database
- **Maestro as Distribution Cache**: Maestro RDS database caches published resources for performance
- **Rebuild Capability**: Maestro cache can be fully reconstructed from CLM if data loss occurs

## Deployment Workflow

The complete deployment sequence shows how Regional and Management infrastructure is provisioned, including the manual certificate transfer process between accounts.

```mermaid
sequenceDiagram
    participant RegOp as Regional<br/>Operator
    participant RegTF as Regional<br/>Terraform
    participant AWS_R as Regional<br/>AWS Account
    participant Transfer as Secure<br/>Transfer Channel
    participant MgmtOp as Management<br/>Operator
    participant MgmtCLI as AWS CLI<br/>(Management)
    participant MgmtTF as Management<br/>Terraform
    participant AWS_M as Management<br/>AWS Account

    Note over RegOp,AWS_M: Phase 1: Regional Infrastructure
    RegOp->>RegTF: terraform apply<br/>maestro-infrastructure
    RegTF->>AWS_R: Create IoT Things + Certs
    RegTF->>AWS_R: Create RDS PostgreSQL
    RegTF->>AWS_R: Create Secrets Manager secrets
    RegTF->>AWS_R: Create Server IAM role + Pod Identity
    AWS_R-->>RegTF: Resources created
    RegTF-->>RegOp: Apply complete

    Note over RegOp,AWS_M: Phase 2: Certificate Extraction
    RegOp->>RegTF: terraform output -json<br/>maestro_agent_certificates
    RegTF-->>RegOp: {"mc01": {<br/>"certificateArn": "...",<br/>"certificatePem": "...",<br/>"privateKey": "...",<br/>"endpoint": "..."}}
    RegOp->>RegOp: jq '["mc01"]' > cert.json
    RegOp->>RegOp: Encrypt cert.json

    Note over RegOp,AWS_M: Phase 3: Secure Transfer
    RegOp->>Transfer: Transfer encrypted cert.json<br/>(GPG / AWS Secrets Manager /<br/>HashiCorp Vault / etc.)
    Transfer->>MgmtOp: Receive encrypted file
    MgmtOp->>MgmtOp: Decrypt cert.json

    Note over RegOp,AWS_M: Phase 4: Management Cluster Secret
    MgmtOp->>MgmtCLI: aws secretsmanager create-secret<br/>--name mc01-maestro-agent-cert<br/>--secret-string file://cert.json
    MgmtCLI->>AWS_M: Create secret in Secrets Manager
    AWS_M-->>MgmtCLI: Secret created
    MgmtOp->>MgmtOp: shred -u cert.json

    Note over RegOp,AWS_M: Phase 5: Management Cluster IAM
    MgmtOp->>MgmtTF: terraform apply<br/>maestro-agent
    MgmtTF->>AWS_M: Create Agent IAM role (same account)
    MgmtTF->>AWS_M: Add IoT permissions (to Regional IoT)
    MgmtTF->>AWS_M: Create Pod Identity association
    AWS_M-->>MgmtTF: Resources created
    MgmtTF-->>MgmtOp: Apply complete

    Note over RegOp,AWS_M: Phase 6: Helm Deployments
    RegOp->>RegTF: terraform output<br/>maestro_configuration_summary
    RegTF-->>RegOp: Helm values (role ARN, secrets, endpoint)
    RegOp->>AWS_R: helm install maestro-server<br/>--set aws.podIdentity.roleArn=...<br/>--set ascp.mqttCertSecretName=...
    AWS_R-->>RegOp: Server deployed

    MgmtOp->>MgmtTF: terraform output helm_values
    MgmtTF-->>MgmtOp: Helm values
    MgmtOp->>AWS_M: helm install maestro-agent<br/>--set maestro.consumerName=mc01<br/>--set broker.endpoint=...
    AWS_M-->>MgmtOp: Agent deployed

    Note over RegOp,AWS_M: Phase 7: Verification
    RegOp->>AWS_R: kubectl logs maestro-server
    AWS_R-->>RegOp: Connected to IoT Core ✓<br/>DB connection established ✓
    MgmtOp->>AWS_M: kubectl logs maestro-agent
    AWS_M-->>MgmtOp: Connected to IoT Core ✓<br/>Subscribed to topic ✓
```

**Why Manual Transfer?**

- Keeps sensitive certificate data OUT of Terraform state
- No automated secrets distribution needed between accounts
- Explicit, auditable security process
- Follows principle of least privilege
- Simplifies secret rotation workflow
- Each cluster maintains sovereignty over its own secrets

## Certificate Transfer Process

The following diagram provides a detailed view of secure certificate transfer between Regional and Management operators.

```mermaid
graph LR
    subgraph Regional["Regional AWS Account<br/>(123456789012)"]
        TF["Terraform Apply<br/>maestro-infrastructure"]
        IoT["AWS IoT Core<br/>Create Certificate"]
        Out["Terraform Output<br/>maestro_agent_certificates<br/>(SENSITIVE)"]

        TF -->|Creates| IoT
        IoT -->|Certificate Data| Out
    end

    subgraph Extract["Regional Operator Actions"]
        Cmd1["terraform output -json<br/>maestro_agent_certificates"]
        JQ["jq '.&#91;&quot;mc01&quot;&#93;'<br/>> cert.json"]
        Encrypt["gpg --encrypt<br/>--recipient management-op<br/>cert.json"]

        Cmd1 --> JQ
        JQ --> Encrypt
    end

    subgraph Transfer["Secure Transfer"]
        Channel["Encrypted Channel<br/>───────────<br/>Options:<br/>• GPG-encrypted email<br/>• AWS Secrets Manager cross-account<br/>• HashiCorp Vault transit<br/>• Secure file share (Box, OneDrive)<br/>• Encrypted S3 bucket"]
    end

    subgraph Receive["Management Operator Actions"]
        Decrypt["gpg --decrypt<br/>cert.json.gpg<br/>> cert.json"]
        Verify["jq . cert.json<br/>(validate JSON)"]
        CLI["aws secretsmanager<br/>create-secret<br/>--secret-string file://cert.json"]
        Shred["shred -u cert.json<br/>(secure delete)"]

        Decrypt --> Verify
        Verify --> CLI
        CLI --> Shred
    end

    subgraph Management["Management AWS Account<br/>(987654321098)"]
        SM["AWS Secrets Manager<br/>mc01-maestro-agent-cert"]
        TF2["Terraform Apply<br/>maestro-agent<br/>(references secret)"]

        SM --> TF2
    end

    Out --> Cmd1
    Encrypt --> Channel
    Channel --> Decrypt
    CLI --> SM

    style Out fill:#fff3cd,stroke:#ffc107,stroke-width:2px
    style Channel fill:#ffe1e1,stroke:#cc0000,stroke-width:3px
    style SM fill:#d4edda,stroke:#28a745,stroke-width:2px
    style Encrypt fill:#ffcccc
    style Decrypt fill:#ccffcc
```

**Certificate Content Structure:**

```json
{
  "certificateArn": "arn:aws:iot:us-east-1:123456789012:cert/abc...",
  "certificatePem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
  "privateKey": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----",
  "endpoint": "abc123.iot.us-east-1.amazonaws.com",
  "port": 8883,
  "consumerName": "mc01"
}
```

This structure contains all necessary information for the Management Cluster agent to authenticate with Regional IoT Core.

## Network Topology

The following diagram shows the physical network layout, VPC isolation, and connectivity patterns across Regional and Management AWS accounts.

```mermaid
graph TB
    subgraph Internet["Internet / AWS Global Services"]
        IoT_Global["AWS IoT Core<br/>Global Service<br/>Endpoint: *.iot.{region}.amazonaws.com:8883"]
    end

    subgraph Regional_Account["Regional AWS Account (123456789012)<br/>Region: us-east-1"]
        subgraph Regional_VPC["VPC: 10.0.0.0/16"]
            subgraph AZ1_R["Availability Zone 1"]
                Pub1_R["Public Subnet<br/>10.0.192.0/22<br/>NAT Gateway"]
                Priv1_R["Private Subnet<br/>10.0.0.0/18<br/>EKS Nodes"]
                DB1_R["RDS Subnet<br/>10.0.201.0/24"]
            end

            subgraph AZ2_R["Availability Zone 2"]
                Pub2_R["Public Subnet<br/>10.0.196.0/22<br/>NAT Gateway"]
                Priv2_R["Private Subnet<br/>10.0.64.0/18<br/>EKS Nodes"]
                DB2_R["RDS Subnet<br/>10.0.202.0/24"]
            end

            IGW_R["Internet Gateway"]
            ALB_R["Application Load Balancer<br/>(Optional - Admin Access)"]

            Priv1_R -->|Route 0.0.0.0/0| Pub1_R
            Priv2_R -->|Route 0.0.0.0/0| Pub2_R
            Pub1_R --> IGW_R
            Pub2_R --> IGW_R

            RDS_R["RDS PostgreSQL<br/>Multi-AZ<br/>Security Group:<br/>Port 5432 from EKS only"]

            DB1_R -.->|Primary| RDS_R
            DB2_R -.->|Standby| RDS_R

            Priv1_R -->|Private connection| RDS_R
            Priv2_R -->|Private connection| RDS_R
        end
    end

    subgraph Mgmt_Account["Management AWS Account (987654321098)<br/>Region: us-east-1"]
        subgraph Mgmt_VPC["VPC: 10.1.0.0/16"]
            subgraph AZ1_M["Availability Zone 1"]
                Pub1_M["Public Subnet<br/>10.1.101.0/24<br/>NAT Gateway"]
                Priv1_M["Private Subnet<br/>10.1.1.0/24<br/>EKS Nodes<br/>Maestro Agent"]
            end

            subgraph AZ2_M["Availability Zone 2"]
                Pub2_M["Public Subnet<br/>10.1.102.0/24<br/>NAT Gateway"]
                Priv2_M["Private Subnet<br/>10.1.2.0/24<br/>EKS Nodes"]
            end

            IGW_M["Internet Gateway"]

            Priv1_M -->|Route 0.0.0.0/0| Pub1_M
            Priv2_M -->|Route 0.0.0.0/0| Pub2_M
            Pub1_M --> IGW_M
            Pub2_M --> IGW_M
        end
    end

    IGW_R -->|HTTPS/TLS<br/>Port 8883| IoT_Global
    IGW_M -->|HTTPS/TLS<br/>Port 8883| IoT_Global

    NoPath["❌ NO DIRECT NETWORK PATH<br/>between Regional VPC and Management VPC"]

    Regional_VPC -.->|No peering<br/>No transit gateway<br/>No VPN| NoPath
    NoPath -.->|No peering<br/>No transit gateway<br/>No VPN| Mgmt_VPC

    style IoT_Global fill:#d4edda,stroke:#28a745,stroke-width:3px
    style RDS_R fill:#e8e8ff,stroke:#6666ff,stroke-width:2px
    style NoPath fill:#ffe1e1,stroke:#cc0000,stroke-width:3px
    style Priv1_R fill:#e1f5ff
    style Priv2_R fill:#e1f5ff
    style Priv1_M fill:#ffe1e1
    style Priv2_M fill:#ffe1e1
```

**Key Network Characteristics:**

- **Complete VPC Isolation**: No VPC peering, no Transit Gateway, no VPN between Regional and Management VPCs
- **Internet Gateway Only**: All clusters access IoT Core through NAT Gateway → Internet Gateway → AWS IoT endpoint
- **Private EKS Clusters**: Control planes have private endpoints only (no public access)
- **RDS Isolation**: Database accessible only from Regional EKS cluster security group
- **Multi-AZ Deployment**: High availability across multiple availability zones
- **Security**: All traffic encrypted in transit (TLS 1.2+)
- **No Direct Paths**: Regional and Management clusters communicate ONLY through AWS IoT Core
- **NAT Gateway Redundancy**: Each availability zone has its own NAT Gateway for resilience

This network topology demonstrates the fundamental isolation principle: Regional and Management clusters have no direct network connectivity, relying entirely on AWS IoT Core as the message broker.

## Benefits

**Network Security & Isolation**:

- Complete network isolation between Regional and Management Clusters (no VPC peering, Transit Gateway, or VPN)
- Management Clusters in separate AWS accounts maintain full autonomy
- Reduced attack surface - no direct API exposure between clusters

**Operational Flexibility**:

- Management Clusters can be provisioned dynamically in any AWS account
- No network topology changes required when adding new Management Clusters
- Simplified disaster recovery - Maestro state rebuilds from CLM

**Event-Driven Performance**:

- Immediate resource propagation (milliseconds vs. seconds with polling)
- Efficient resource utilization - no continuous polling overhead
- Reliable delivery with MQTT QoS 1 guarantees

**Strategic Alignment**:

- Leverages proven Maestro technology from ARO-HCP production deployments
- Aligns with AWS-native architecture (IoT Core, IAM, Secrets Manager)
- Foundation for future event-driven workflows beyond resource distribution
- Compatible with multi-region and multi-cloud expansion strategies

**Scalability & Performance**:

- **Horizontal Scaling**: Maestro Server runs with multiple replicas (2+) for high availability
- **Connection Pooling**: Each agent maintains a single persistent MQTT connection (no polling overhead)
- **Message Batching**: CloudEvent envelope supports batch operations for efficiency
- **Topic-Based Routing**: AWS IoT Core handles message routing at the broker level
- **QoS Guarantees**: MQTT QoS 1 ensures at-least-once delivery with minimal latency

**Operational Advantages**:

- **Observability**: AWS IoT Core provides CloudWatch metrics for connection health, message throughput, and error rates
- **Auditability**: All MQTT connections and message deliveries logged in CloudTrail
- **Certificate Rotation**: Manual transfer process enables controlled, auditable certificate lifecycle management
- **Disaster Recovery**: Regional Maestro RDS can be rebuilt from CLM source of truth
- **Testing & Validation**: Easy to test with mock MQTT clients for integration testing

## Operational Considerations

### Monitoring & Alerting

**CloudWatch Metrics**:

- `AWS/IoT/Connect.Success` - Monitor successful MQTT connections
- `AWS/IoT/PublishIn.Success` - Track message publication rates
- `AWS/IoT/Subscribe.Success` - Verify agent subscriptions
- Custom metrics from Maestro Server/Agent for ManifestWork processing

**Health Checks**:

- Maestro Server: HTTP `/healthz` endpoint on port 8080
- Maestro Agent: Kubernetes liveness/readiness probes
- RDS: Automated CloudWatch alarms for connection count, CPU, and storage

### Troubleshooting Guide

**Agent Cannot Connect to IoT Core**:

1. Verify IAM role has cross-account IoT permissions
2. Check certificate validity: `openssl x509 -in cert.pem -text -noout`
3. Validate IoT endpoint: `nslookup <endpoint>.iot.<region>.amazonaws.com`
4. Review agent logs for authentication errors
5. Confirm NAT Gateway and Internet Gateway routing

**Messages Not Delivered**:

1. Check MQTT topic subscriptions match publication topics
2. Verify IoT Policy allows subscribe/publish on correct topics
3. Review CloudWatch Logs for IoT Core rule errors
4. Confirm QoS level matches (should be QoS 1)
5. Check Maestro Server database connection to RDS

**Certificate Rotation**:

1. Create new certificate in Regional IoT Core
2. Extract certificate using Terraform output
3. Transfer encrypted certificate to Management operator
4. Update Management Secrets Manager secret
5. Restart Maestro Agent pods to reload secret
6. Deactivate old certificate in IoT Core (after 24-hour grace period)
7. Delete old certificate

### Performance Tuning

- **RDS Instance Sizing**: Start with `db.t4g.micro`, scale to `db.t4g.medium` for 50+ Management Clusters
- **Connection Limits**: AWS IoT Core supports 100,000 concurrent connections per account (adjust quotas if needed)
- **Message Throughput**: Default IoT Core message throughput is sufficient for 1000s of ManifestWork operations/minute
- **Network Bandwidth**: NAT Gateway bandwidth auto-scales; monitor CloudWatch metrics for saturation

### Cost Optimization

- **IoT Core Pricing**: Pay per message published/delivered (~$1 per million messages)
- **RDS Costs**: Use reserved instances for production Regional clusters (40-60% savings)
- **Secrets Manager**: $0.40/secret/month - negligible for typical deployments
- **Data Transfer**: NAT Gateway data transfer charges apply ($0.045/GB outbound)

## Related Documentation

### Terraform Infrastructure Modules

- **[maestro-infrastructure](../../terraform/modules/maestro-infrastructure/)** - Regional cluster Maestro server infrastructure
  - IoT Core provisioning (Things, Certificates, Policies)
  - RDS PostgreSQL database
  - Secrets Manager configuration
  - Server IAM roles and Pod Identity associations

- **[maestro-agent](../../terraform/modules/maestro-agent/)** - Management cluster Maestro agent infrastructure
  - Agent IAM roles with cross-account IoT permissions
  - Pod Identity associations (same-account)
  - Helm chart value generation

### Design Decisions

- **[fully-private-eks-bootstrap.md](./fully-private-eks-bootstrap.md)** - ECS-based bootstrap strategy for fully private EKS clusters

### External References

- **[Maestro Project](https://github.com/openshift-online/maestro)** - Upstream Maestro orchestration system
- **[ARO-HCP](https://github.com/Azure/ARO-HCP)** - Azure Red Hat OpenShift HCP implementation using Maestro
- **[AWS IoT Core MQTT](https://docs.aws.amazon.com/iot/latest/developerguide/mqtt.html)** - AWS IoT Core MQTT protocol documentation
- **[AWS Secrets Store CSI Driver](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html)** - ASCP integration with EKS
- **[EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)** - AWS EKS Pod Identity documentation

### Configuration Files

- **[argocd/config/regional-cluster/maestro/](../../argocd/config/regional-cluster/maestro/)** - Maestro Server Helm chart configurations
- **[argocd/config/management-cluster/maestro/](../../argocd/config/management-cluster/maestro/)** - Maestro Agent Helm chart configurations

---

**Decision Date**: January 30, 2026
**Decision Maker**: RRP Team
**Review Date**: June 30, 2026 (6-month review cycle)
