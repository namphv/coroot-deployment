# Coroot Monitoring System Design for GKE

## Overview

This document outlines the system design for deploying Coroot, an eBPF-based observability and APM platform, on Google Kubernetes Engine (GKE) with external ClickHouse and VictoriaMetrics instead of the default embedded components.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GKE Cluster                              │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                   Monitoring Namespace                    │  │
│  │                                                            │  │
│  │  ┌──────────────┐      ┌──────────────┐                  │  │
│  │  │   Coroot     │◄─────┤ VictoriaMetrics                │  │
│  │  │   Server     │      │   Cluster     │                  │  │
│  │  │              │      │               │                  │  │
│  │  │ - Web UI     │      │ - vmselect    │                  │  │
│  │  │ - Analysis   │      │ - vminsert    │                  │  │
│  │  │ - Alerting   │      │ - vmstorage   │                  │  │
│  │  └──────┬───────┘      └───────▲───────┘                  │  │
│  │         │                      │                           │  │
│  │         │                      │                           │  │
│  │         ▼                      │                           │  │
│  │  ┌──────────────┐      ┌───────┴────────┐                │  │
│  │  │  ClickHouse  │      │  Prometheus     │                │  │
│  │  │   Cluster    │      │  Remote Write   │                │  │
│  │  │              │      │   Receiver      │                │  │
│  │  │ - Logs       │      └─────────────────┘                │  │
│  │  │ - Traces     │                                          │  │
│  │  │ - Profiles   │                                          │  │
│  │  └──────────────┘                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              Application Workload Nodes                   │  │
│  │                                                            │  │
│  │  ┌────────────────────────────────────────────────┐      │  │
│  │  │           Coroot Node Agent (DaemonSet)        │      │  │
│  │  │                                                  │      │  │
│  │  │  - eBPF metrics collection                     │      │  │
│  │  │  - Application profiling                       │      │  │
│  │  │  - Network tracing                             │      │  │
│  │  │  - Pushes to VictoriaMetrics via Remote Write  │      │  │
│  │  └────────────────────────────────────────────────┘      │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Coroot Server
- **Purpose**: Central observability platform with AI-powered root cause analysis
- **Deployment**: StatefulSet or Deployment with 2-3 replicas
- **Resources**: CPU: 2-4 cores, Memory: 4-8GB per pod
- **Node Placement**: Regular (non-spot) nodes for stability
- **Storage**: Persistent volume for internal cache

### 2. VictoriaMetrics Cluster
- **Purpose**: Time-series metrics storage (Prometheus-compatible)
- **Components**:
  - **vmselect**: Query interface (2 replicas)
  - **vminsert**: Data ingestion (2 replicas)
  - **vmstorage**: Data storage (3 replicas with persistent volumes)
- **Resources**:
  - vmselect: CPU: 1-2 cores, Memory: 2-4GB
  - vminsert: CPU: 1-2 cores, Memory: 2-4GB
  - vmstorage: CPU: 2-4 cores, Memory: 4-8GB, Disk: 500GB-2TB SSD per replica
- **Node Placement**: vmstorage on regular nodes, vmselect/vminsert can use spot nodes
- **Retention**: 30-90 days (configurable)

### 3. ClickHouse Cluster
- **Purpose**: Storage for logs, traces, and continuous profiling data
- **Deployment**: StatefulSet with 2-3 shards, 2 replicas each
- **Resources**: CPU: 4-8 cores, Memory: 16-32GB per pod, Disk: 1-5TB SSD per replica
- **Node Placement**: Regular nodes (critical data storage)
- **HA Setup**: ZooKeeper or ClickHouse Keeper for coordination

### 4. Coroot Node Agent
- **Purpose**: eBPF-based data collection from application nodes
- **Deployment**: DaemonSet (runs on every node)
- **Resources**: CPU: 200-500m, Memory: 512MB-1GB per node
- **Privileges**: Requires privileged mode for eBPF
- **Node Placement**: All application nodes (both spot and regular)

## GKE Cluster Configuration

### Node Pools

#### 1. Monitoring Node Pool (Regular Nodes)
- **Purpose**: Run critical monitoring infrastructure
- **Machine Type**: n2-standard-8 (8 vCPU, 32GB RAM)
- **Node Count**: 3 nodes (min: 2, max: 5)
- **Disk**: 200GB SSD per node
- **Preemptible**: No
- **Taints**: `monitoring=critical:NoSchedule`
- **Labels**: `node-type=monitoring`, `workload=monitoring`

#### 2. Application Workload Pool (Spot Nodes)
- **Purpose**: Run application workloads
- **Machine Type**: n2-standard-16 or n2-highmem-16
- **Node Count**: Auto-scaling (min: 2, max: 20)
- **Disk**: 100GB SSD per node
- **Preemptible**: Yes (Spot VMs for cost savings)
- **Labels**: `node-type=workload`, `spot=true`

#### 3. Storage Node Pool (Regular Nodes)
- **Purpose**: Run stateful workloads (ClickHouse, VictoriaMetrics storage)
- **Machine Type**: n2-highmem-8 (8 vCPU, 64GB RAM)
- **Node Count**: 3-6 nodes
- **Disk**: 200GB SSD per node + attached persistent disks
- **Preemptible**: No
- **Taints**: `storage=critical:NoSchedule`
- **Labels**: `node-type=storage`, `workload=stateful`
- **Local SSDs**: Optional for better I/O performance

### Cluster Settings
- **Region**: Multi-zonal for HA (e.g., us-central1-a, us-central1-b, us-central1-c)
- **Kubernetes Version**: Latest stable (1.28+)
- **Network Policy**: Enabled
- **Workload Identity**: Enabled
- **GKE Autopilot**: No (Standard mode for more control)

## Data Flow

1. **Metrics Collection**:
   - Coroot Node Agents collect metrics via eBPF
   - Agents push metrics to VictoriaMetrics (vminsert) via Prometheus Remote Write
   - Coroot Server queries metrics from VictoriaMetrics (vmselect)

2. **Logs, Traces, and Profiles**:
   - Coroot Node Agents collect and send data directly to Coroot Server
   - Coroot Server stores in ClickHouse cluster

3. **Visualization and Analysis**:
   - Users access Coroot Web UI (LoadBalancer or Ingress)
   - Coroot performs AI-powered analysis on metrics, logs, and traces

## High Availability

### Coroot Server
- 2-3 replicas with anti-affinity rules
- PostgreSQL backend for multi-instance support
- LoadBalancer service for HA

### VictoriaMetrics
- Multiple vmselect/vminsert replicas (stateless)
- vmstorage replicas with persistent volumes
- Data replication factor: 2

### ClickHouse
- 2 replicas per shard
- ZooKeeper/ClickHouse Keeper cluster (3 nodes)
- Distributed table engine for queries

## Resource Sizing

### Small Deployment (Development/Testing)
- **Cluster**: 3 regular nodes (n2-standard-4) + 2-5 spot nodes
- **VictoriaMetrics**: 1GB vmstorage, 3-day retention
- **ClickHouse**: 1 shard, 2 replicas, 100GB storage
- **Estimated Cost**: $300-500/month

### Medium Deployment (Production)
- **Cluster**: 3 monitoring + 3 storage + 5-15 spot nodes
- **VictoriaMetrics**: 500GB vmstorage, 30-day retention
- **ClickHouse**: 2 shards, 2 replicas, 1TB storage
- **Estimated Cost**: $1,500-2,500/month

### Large Deployment (Enterprise)
- **Cluster**: 5 monitoring + 6 storage + 20-50 spot nodes
- **VictoriaMetrics**: 2TB vmstorage, 90-day retention
- **ClickHouse**: 3 shards, 2 replicas, 5TB storage
- **Estimated Cost**: $5,000-10,000/month

## Security Considerations

1. **Network Policies**: Restrict traffic between namespaces
2. **RBAC**: Least privilege access for service accounts
3. **Secrets Management**: Use Google Secret Manager or Sealed Secrets
4. **TLS**: Enable TLS for all inter-component communication
5. **Authentication**: Configure Coroot with SSO/OAuth
6. **Pod Security**: Use Pod Security Standards (restricted)

## Monitoring and Alerting

1. **Self-Monitoring**: Coroot monitors its own components
2. **GKE Monitoring**: Enable GKE monitoring and logging
3. **Alerts**: Configure alerts for:
   - High resource usage
   - Pod failures
   - Storage capacity
   - Query latency

## Backup and Disaster Recovery

1. **VictoriaMetrics**: Volume snapshots (GCP persistent disk snapshots)
2. **ClickHouse**: Regular backups using clickhouse-backup tool
3. **Coroot Configuration**: GitOps approach with version-controlled manifests
4. **Recovery Time Objective (RTO)**: < 1 hour
5. **Recovery Point Objective (RPO)**: < 15 minutes

## Cost Optimization

1. **Spot Nodes**: Use for application workloads (60-90% cost savings)
2. **Right-Sizing**: Monitor and adjust resource requests/limits
3. **Data Retention**: Implement tiered storage or reduced retention
4. **Regional Disks**: Use regional persistent disks for HA without extra replicas
5. **Committed Use Discounts**: For predictable monitoring workload

## Migration Path

1. **Phase 1**: Deploy VictoriaMetrics and ClickHouse
2. **Phase 2**: Deploy Coroot with external dependencies
3. **Phase 3**: Deploy Node Agents to application nodes
4. **Phase 4**: Configure projects and dashboards
5. **Phase 5**: Migrate from existing monitoring (if any)

## Scalability Considerations

- **Horizontal Scaling**: Add more vminsert/vmselect replicas as query load increases
- **Vertical Scaling**: Increase vmstorage and ClickHouse resources for data growth
- **Sharding**: Add ClickHouse shards when single-shard performance degrades
- **Federation**: Use VictoriaMetrics federation for multi-cluster setups

## Dependencies

- **Kubernetes**: 1.25+
- **Helm**: 3.10+
- **kubectl**: Latest version
- **gcloud CLI**: For GKE management

## Configuration Management

All configurations are managed as Infrastructure as Code:
- Helm charts for application deployment
- Terraform for GKE cluster provisioning
- GitOps for continuous deployment (ArgoCD/FluxCD recommended)
