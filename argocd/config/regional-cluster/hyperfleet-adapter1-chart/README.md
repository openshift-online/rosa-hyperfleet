# Hyperfleet Adapter1 - Cluster Status Handling

This document describes how adapter1 monitors and reports cluster status conditions to the Platform API.

## Overview

Adapter1 manages the lifecycle of HostedClusters by:

1. Creating ManifestWork resources containing HostedCluster and NodePool manifests
2. Monitoring HostedCluster status via feedback rules configured in the ManifestWork
3. Aggregating status into conditions and posting to `/clusters/{clusterId}/statuses`

## Status Feedback Flow

```mermaid
graph LR
    A[Adapter1] -->|Creates| B[ManifestWork]
    B -->|Delivered to| C[Management Cluster]
    C -->|Applies| D[HostedCluster]
    D -->|Status Feedback| E[Maestro]
    E -->|Syncs to| F[Regional Cluster]
    F -->|Read by| A
    A -->|POST| G[/clusters/id/statuses]
```

## Cluster Status Conditions

Adapter1 reports three conditions for each cluster to the Platform API:

| Condition     | Source                                        | Status Logic                                                                                                | Purpose                                                                                           |
| ------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| **Applied**   | ManifestWork `.status.conditions[Applied]`    | `True` if Maestro successfully applied the ManifestWork<br>`False` if not yet applied or application failed | Indicates whether the cluster manifests have been delivered and applied to the management cluster |
| **Health**    | HostedCluster `.status.conditions[Degraded]`  | `True` if degradedCondition = "False"<br>`False` if degraded or feedback not available                      | Indicates whether the HostedCluster control plane is healthy (not degraded)                       |
| **Available** | HostedCluster `.status.conditions[Available]` | Value from availableCondition<br>`False` if feedback not available                                          | Indicates whether the HostedCluster API is available and serving requests                         |

## Status Values and Reasons

### Applied Condition

| Status  | Reason                   | Message                                         | When                                                    |
| ------- | ------------------------ | ----------------------------------------------- | ------------------------------------------------------- |
| `True`  | _(from ManifestWork)_    | _(from ManifestWork)_                           | ManifestWork has been applied successfully              |
| `False` | `ManifestWorkNotApplied` | `ManifestWork not yet applied by Maestro agent` | ManifestWork does not exist or has no Applied condition |

### Health Condition

| Status  | Reason                  | Message                                     | When                                                      |
| ------- | ----------------------- | ------------------------------------------- | --------------------------------------------------------- |
| `True`  | `NotDegraded`           | `HostedCluster is healthy`                  | HostedCluster degradedCondition = "False"                 |
| `False` | `HostedClusterDegraded` | `HostedCluster is degraded`                 | HostedCluster degradedCondition = "True"                  |
| `False` | `StatusNotReady`        | `Waiting for HostedCluster status feedback` | Status feedback not yet available from management cluster |

### Available Condition

| Status  | Reason                      | Message                                     | When                                                      |
| ------- | --------------------------- | ------------------------------------------- | --------------------------------------------------------- |
| `True`  | `HostedClusterAvailable`    | `HostedCluster is available`                | HostedCluster availableCondition = "True"                 |
| `False` | `HostedClusterNotAvailable` | `HostedCluster not yet available`           | HostedCluster availableCondition = "False"                |
| `False` | `StatusNotReady`            | `Waiting for HostedCluster status feedback` | Status feedback not yet available from management cluster |

## Status Feedback Configuration

The adapter configures ManifestWork feedbackRules to retrieve HostedCluster conditions:

```yaml
manifestConfigs:
  - resourceIdentifier:
      group: "hypershift.openshift.io"
      resource: "hostedclusters"
      namespace: "clusters-{{ .clusterId }}"
      name: "{{ .clusterName }}"
    feedbackRules:
      - type: "JSONPaths"
        jsonPaths:
          - name: "availableCondition"
            path: '.status.conditions[?(@.type=="Available")].status'
          - name: "degradedCondition"
            path: '.status.conditions[?(@.type=="Degraded")].status'
          - name: "controlPlaneEndpoint"
            path: ".status.controlPlaneEndpoint.host"
          - name: "version"
            path: ".status.version.history[0].version"
```

## POST Payload Format

The adapter sends status updates to `/clusters/{clusterId}/statuses` with this structure:

```json
{
  "adapter": "adapter1",
  "conditions": [
    {
      "type": "Applied",
      "status": "True|False",
      "reason": "...",
      "message": "..."
    },
    {
      "type": "Health",
      "status": "True|False",
      "reason": "...",
      "message": "..."
    },
    {
      "type": "Available",
      "status": "True|False",
      "reason": "...",
      "message": "..."
    }
  ],
  "observed_generation": 1,
  "observed_time": "2026-04-09T12:00:00Z",
  "data": {
    "namespace": { "name": "clusters-{id}", "creationTimestamp": "..." },
    "hostedCluster": {
      "name": "cluster-name",
      "apiEndpoint": "https://api.example.com",
      "version": "4.21.1"
    }
  }
}
```

## Cluster Ready State

For the Platform API to mark a cluster as **Ready**, all required adapters must report:

- `Applied: True`
- `Health: True`
- `Available: True`

**Note:** Only `adapter1` is currently required. Previously `adapter2` was also required, which prevented clusters from reaching Ready state since adapter2 is not deployed.

## Important Design Decisions

1. **No Unknown Status**: When status feedback is not available, conditions return `False` rather than `Unknown`. This ensures the cluster does not prematurely show as Ready before the HostedCluster control plane is actually healthy.

2. **Status vs. Reason/Message**: The `status` field is the primary signal (True/False). The `reason` and `message` provide additional context for debugging but should not be used for decision logic.

3. **Feedback Delay**: There is an inherent delay between ManifestWork application and status feedback availability. The adapter handles missing feedback gracefully by returning False with StatusNotReady reason.

## Related Configuration

- **Adapter Values**: `argocd/config/regional-cluster/hyperfleet-adapter1-chart/values.yaml`
- **Adapter Task Config**: `argocd/config/regional-cluster/hyperfleet-adapter1-chart/adapter-task-config.yaml`
- **API Required Adapters**: `argocd/config/regional-cluster/hyperfleet-api-chart/values.yaml` (specifies `adapter1` only)
