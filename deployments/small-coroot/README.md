# Small Coroot Deployment

Complete, self-contained deployment for Coroot with ClickHouse optimized for small environments (2 regular nodes + 1 big spot node).

## Overview

**All components in `coroot` namespace:**
- ClickHouse Keeper (3 replicas, ~450MB total)
- ClickHouse Cluster (1 shard, 2 replicas)
  - Anchor: Regular node, 2GB RAM, 50GB storage (fallback)
  - Worker: Spot node, 16-32GB RAM, 500GB storage (80-90% traffic)
- Coroot Server (unified ClickHouse storage for metrics + logs + traces)
- Coroot Node Agents (DaemonSet on all nodes)
- PostgreSQL (Coroot metadata)

## Prerequisites

- Kubernetes cluster with:
  - 2 regular nodes (n2-standard-4 or similar)
  - 1 spot node (n2-highmem-16 or similar)
  - Spot nodes labeled with `cloud.google.com/gke-spot=true`
- kubectl configured
- Helm 3.10+

## Quick Start

```bash
# Deploy everything
./deploy.sh

# Wait for all pods to be ready
kubectl get pods -n coroot -w

# Access Coroot
kubectl port-forward -n coroot svc/coroot 8080:8080

# Open http://localhost:8080
# Default credentials: admin / admin
```

## File Structure

```
deployments/small-coroot/
├── 00-namespace.yaml           # Namespace definition
├── 01-clickhouse-keeper.yaml   # ClickHouse Keeper (3 replicas)
├── 02-clickhouse-cluster.yaml  # ClickHouse (1 shard, 2 replicas)
├── 03-coroot-values.yaml       # Coroot Helm values
├── deploy.sh                   # One-command deployment
└── README.md                   # This file
```

## Manual Deployment

If you prefer to deploy step-by-step:

```bash
# 1. Create namespace
kubectl apply -f 00-namespace.yaml

# 2. Install ClickHouse Operator
kubectl apply -f https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator/clickhouse-operator-install-bundle.yaml

# Wait for operator
kubectl wait --for=condition=ready pod -l app=clickhouse-operator -n kube-system --timeout=300s

# 3. Deploy ClickHouse Keeper
kubectl apply -f 01-clickhouse-keeper.yaml

# Wait for Keeper
kubectl wait --for=condition=ready pod -l app=clickhouse-keeper -n coroot --timeout=300s

# 4. Deploy ClickHouse Cluster
kubectl apply -f 02-clickhouse-cluster.yaml

# Wait for ClickHouse
kubectl wait --for=condition=ready pod -l clickhouse.altinity.com/app=chop -n coroot --timeout=600s

# 5. Install Coroot
helm repo add coroot https://coroot.github.io/helm-charts
helm repo update

helm upgrade --install coroot coroot/coroot \
  --namespace coroot \
  --values 03-coroot-values.yaml \
  --wait \
  --timeout=10m
```

## Configuration

### Change Passwords

**ClickHouse password:**
```bash
# Generate new password hash
echo -n "your-secure-password" | sha256sum

# Update in 02-clickhouse-cluster.yaml:
coroot/password_sha256_hex: "YOUR_HASH_HERE"

# Update in 03-coroot-values.yaml:
externalClickhouse:
  password: your-secure-password

# Reapply
kubectl apply -f 02-clickhouse-cluster.yaml
helm upgrade coroot coroot/coroot -n coroot -f 03-coroot-values.yaml
```

**Coroot admin password:**
- Change via Coroot UI after first login

**PostgreSQL password:**
```yaml
# In 03-coroot-values.yaml
postgresql:
  auth:
    password: your-secure-pg-password
```

### Adjust Resources

**For smaller regular nodes:**
```yaml
# In 02-clickhouse-cluster.yaml, anchor template:
resources:
  requests:
    cpu: 300m        # Reduce from 500m
    memory: 1.5Gi    # Reduce from 2Gi
```

**For larger spot node:**
```yaml
# In 02-clickhouse-cluster.yaml, worker template:
resources:
  requests:
    cpu: 8000m       # Increase from 4000m
    memory: 64Gi     # Increase from 16Gi
  limits:
    cpu: 16000m      # Increase from 8000m
    memory: 96Gi     # Increase from 32Gi
```

### Enable LoadBalancer

```yaml
# In 03-coroot-values.yaml:
corootCE:
  service:
    type: LoadBalancer
```

## Verification

### Check Deployment

```bash
# All pods should be Running
kubectl get pods -n coroot

# Expected pods:
# - clickhouse-keeper-0, -1, -2
# - chi-coroot-clickhouse-coroot-cluster-0-0-0 (anchor, regular node)
# - chi-coroot-clickhouse-coroot-cluster-0-1-0 (worker, spot node)
# - coroot-0 (or coroot-xxx)
# - coroot-postgresql-0
# - coroot-node-agent-xxx (one per node)
# - coroot-cluster-agent-xxx
```

### Verify Traffic Routing

```bash
# Check which replica is handling queries (should be 80-90% on worker)
kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \
  clickhouse-client --user=coroot --password=coroot123 --query="
    SELECT
      hostName() as replica,
      count() as queries,
      round(100 * count() / sum(count()) OVER (), 1) as percent
    FROM system.query_log
    WHERE event_time > now() - 300
      AND type = 'QueryFinish'
    GROUP BY hostName()
    ORDER BY queries DESC"

# Expected output:
# worker-0-1-0    ~90%   ← Spot node (most traffic)
# anchor-0-0-0    ~10%   ← Regular node (fallback)
```

### Check Resource Usage

```bash
# Pod resource usage
kubectl top pods -n coroot

# Node resource usage
kubectl top nodes

# Expected:
# Regular nodes: 5-20% CPU (minimal usage)
# Spot node: 60-90% CPU (doing most work)
```

## Architecture Details

### Node Placement

**Regular Node 1:**
- ClickHouse Keeper-0: 100m CPU, 128Mi RAM
- ClickHouse Anchor: 500m CPU, 2Gi RAM
- **Total: ~2.5GB RAM**

**Regular Node 2:**
- ClickHouse Keeper-1: 100m CPU, 128Mi RAM
- Coroot Server: 500m CPU, 2Gi RAM
- PostgreSQL: 250m CPU, 512Mi RAM
- **Total: ~2.6GB RAM**

**Spot Node:**
- ClickHouse Keeper-2: 100m CPU, 128Mi RAM
- ClickHouse Worker: 4-8 CPU, 16-32Gi RAM
- Node Agents: 200m CPU, 512Mi RAM
- **Total: ~16-32GB RAM (handles 80-90% of traffic)**

### Data Strategy

**Anchor Replica (Regular Node):**
- Stores: Last 7 days of data
- Purpose: Hot data, guaranteed availability
- Priority: Low (fallback only)
- TTL: Auto-prunes old data

**Worker Replica (Spot Node):**
- Stores: 30-90 days of data
- Purpose: Main workload, all queries
- Priority: High (preferred for queries)
- Can be preempted (recovers in 15-30 min)

### Unified Storage

All observability data in ClickHouse:
- ✅ Metrics (via `GLOBAL_PROMETHEUS_USE_CLICKHOUSE=true`)
- ✅ Logs
- ✅ Traces
- ✅ Continuous profiling

**No VictoriaMetrics needed!**

## Monitoring

### Query Distribution

```bash
# Monitor which replica is serving queries
watch -n 5 'kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \
  clickhouse-client --user=coroot --password=coroot123 --query="
    SELECT hostName(), count()
    FROM system.query_log
    WHERE event_time > now() - 60
    GROUP BY hostName()"'
```

### Resource Usage

```bash
# Real-time pod resources
watch -n 5 'kubectl top pods -n coroot --sort-by=memory'
```

### ClickHouse Health

```bash
# Check cluster status
kubectl get chi -n coroot

# Check replica status
kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \
  clickhouse-client --query="SELECT * FROM system.clusters WHERE cluster='coroot_cluster'"
```

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -n coroot

# Describe problematic pod
kubectl describe pod <pod-name> -n coroot

# Check logs
kubectl logs <pod-name> -n coroot
```

### ClickHouse Connection Issues

```bash
# Test ClickHouse connectivity
kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \
  clickhouse-client --user=coroot --password=coroot123 --query="SELECT 1"

# Check ClickHouse logs
kubectl logs -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0
```

### Metrics Not Appearing in Coroot

```bash
# Check Coroot logs
kubectl logs -n coroot -l app.kubernetes.io/name=coroot

# Check node agent is collecting
kubectl logs -n coroot -l app.kubernetes.io/name=coroot-node-agent --tail=50

# Verify ClickHouse has data
kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \
  clickhouse-client --user=coroot --password=coroot123 --query="SHOW TABLES"
```

### Spot Node Preemption

When spot node is preempted:
1. Worker replica terminates gracefully (30s)
2. Queries automatically route to anchor replica
3. Performance degrades temporarily (2-5x slower)
4. New spot node spawns (2-5 min)
5. Worker rejoins and resyncs (10-30 min)
6. Performance returns to normal

**This is expected and acceptable for observability workloads.**

## Uninstall

```bash
# Remove Coroot
helm uninstall coroot -n coroot

# Remove ClickHouse cluster
kubectl delete chi coroot-clickhouse -n coroot

# Remove ClickHouse Keeper
kubectl delete statefulset clickhouse-keeper -n coroot
kubectl delete svc clickhouse-keeper clickhouse-keeper-headless -n coroot
kubectl delete cm clickhouse-keeper-config -n coroot

# Remove namespace (careful - this deletes all PVCs!)
kubectl delete namespace coroot
```

## Cost Estimate

Example for GCP:
- 2 × n2-standard-4 (regular): $240/month
- 1 × n2-highmem-16 (spot): $160/month
- Storage (50GB + 500GB): $70/month
- **Total: ~$470/month**

vs All on-demand: ~$920/month
**Savings: 49%**

## Documentation Links

- [Small Efficient Architecture](../../SMALL_EFFICIENT_CLICKHOUSE.md)
- [Traffic Routing Optimization](../../TRAFFIC_ROUTING_OPTIMIZATION.md)
- [Unified ClickHouse Design](../../UNIFIED_CLICKHOUSE_ARCHITECTURE.md)
- [Spot Node Strategy](../../CLICKHOUSE_SPOT_ARCHITECTURE.md)

## Support

For issues:
- Check troubleshooting section above
- Review main documentation
- Check ClickHouse Operator docs: https://github.com/Altinity/clickhouse-operator
- Check Coroot docs: https://docs.coroot.com/
