# Small Coroot Deployment

Complete, self-contained deployment for Coroot with ClickHouse optimized for small environments (2 regular nodes + 1 big spot node).

## Overview

**All components in `coroot` namespace:**
- ClickHouse Keeper (3 replicas, ~450MB total)
- ClickHouse Cluster (1 shard, 2 replicas)
  - Anchor: Regular node, 1GB RAM, 30GB pd-balanced (replication + fallback)
  - Worker: Spot node, 6-15GB RAM, 500GB pd-balanced (main workload)
- **Nginx Proxy** (2 replicas): Weighted routing (90% worker, 10% anchor) + auto-failover
- Coroot Server (unified ClickHouse storage for metrics + logs + traces)
- Coroot Node Agents (DaemonSet on all nodes)
- PostgreSQL (Coroot metadata)

**Resource Sharing on Spot Node:**
- ClickHouse Worker configured to coexist with Chrome Headless deployment
- ClickHouse requests: 1.5 CPU + 6GB RAM (guaranteed minimum)
- ClickHouse limits: No CPU limit (can burst), 15GB RAM (hard cap)
- Chrome Headless: 3-6 CPU + 3-12GB RAM
- Total: Fits in 7.9 CPU + 27.6GB available on spot node

## Architecture Highlights

**Write & Read Path:**
```
Coroot → Nginx Proxy (weighted routing)
           ├─ 90%: Worker (spot node, strong: 1.5+ CPU, 6-15GB RAM) ⚡
           └─ 10%: Anchor (regular node, weak: 200m CPU, 1GB RAM, backup only) 💤

When spot node down:
Coroot → Nginx Proxy (automatic failover)
           └─ 100%: Anchor (fallback mode)

Data replication (automatic):
Anchor ←---ClickHouse Keeper---→ Worker
  (Both replicas have identical data)
```

**Why Nginx proxy instead of Kubernetes Service:**
- ❌ **K8s Service**: Round-robin 50/50 (wastes strong worker node)
- ✅ **Nginx Proxy**: Primary+backup routing (100% worker when up, 0% anchor)
- ✅ **Backup mode**: Anchor only receives traffic when worker fails
- ✅ Health checks: Automatic failover when worker unavailable (max_fails=2, fail_timeout=10s)
- ✅ Writes succeed even during spot node restart (2-5 sec latency)
- ✅ Session affinity keeps queries on same replica for consistency

## Storage Considerations

**⚠️ Important: Storage Size Mismatch**

Current configuration has a storage mismatch:
- Anchor: 30GB storage
- Worker: 500GB storage
- **Problem**: Replicas should have same capacity, but anchor only has 30GB

**When worker data exceeds 30GB, replication will fail!**

**Solutions:**

1. **Increase anchor storage** to match worker (500GB both)
   - Cost: $50/month for anchor
   - Simple but expensive

2. **Reduce both to same size** (e.g., 200GB both)
   - Cost: $20/month each ($40 total)
   - Less retention but affordable

3. **Enable tiered storage** (Recommended - see [TIERED_STORAGE_SETUP.md](TIERED_STORAGE_SETUP.md))
   - Both: 100GB local + GCS cold tier
   - Cost: $28/month total (saves 47%)
   - Unlimited retention, auto-tiering after 7 days

## Prerequisites

- Kubernetes cluster with:
  - 2 regular nodes (n2-standard-4 or similar)
  - 1 spot node (7.9 CPU, 27.6GB RAM - e.g., n2-highmem-8 or similar)
  - Spot nodes labeled with `cloud.google.com/gke-spot=true`
  - **Note:** Spot node shared with Chrome Headless (Chrome has priority)
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
├── 00-namespace.yaml                # Namespace definition
├── 01-clickhouse-keeper.yaml        # ClickHouse Keeper (3 replicas)
├── 02-clickhouse-cluster.yaml       # ClickHouse (1 shard, 2 replicas) + tiered storage config
├── 02a-clickhouse-service.yaml      # Direct service (optional, for manual testing)
├── 02b-clickhouse-nginx-proxy.yaml  # Nginx proxy (primary+backup routing)
├── 02c-clickhouse-tiered-storage.yaml  # Tiered storage reference (deprecated, see 02-clickhouse-cluster.yaml)
├── 03-coroot-values.yaml            # Coroot Helm values
├── deploy.sh                        # One-command deployment
├── README.md                        # This file
└── TIERED_STORAGE_SETUP.md          # Guide to enable GCS-backed tiered storage
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

### Resource Behavior

**Spot Node Sharing (ClickHouse Worker + Chrome Headless):**

```
Scheduling (Kubernetes guarantees):
├─ Chrome requests:      3 CPU + 3 GB
├─ ClickHouse requests:  1.5 CPU + 6 GB
└─ Sum:                  4.5 CPU + 9 GB  ✅ Can schedule

Runtime Behavior:
├─ When Chrome is idle (1.5 CPU + 2 GB):
│   └─ ClickHouse can burst to ~6 CPU (no CPU limit)
│
├─ When Chrome peaks (6 CPU + 5 GB):
│   ├─ ClickHouse throttled to ~1.5-2 CPU (guaranteed minimum)
│   └─ Memory: 5 GB + 6-15 GB = 11-20 GB (safe)
│
└─ Max memory usage:
    └─ Chrome (12 GB limit) + ClickHouse (15 GB limit) = 27 GB < 27.6 GB ✅
```

**Why no CPU limit on ClickHouse?**
- CPU is compressible (Kubernetes can throttle without killing pods)
- ClickHouse bursts to use spare CPU when Chrome is idle
- Natural resource sharing based on actual demand
- Better performance for observability queries

### Adjust Resources

**If spot node has MORE resources available:**
```yaml
# In 02-clickhouse-cluster.yaml, worker template:
resources:
  requests:
    cpu: 2000m       # Increase guaranteed CPU
    memory: 8Gi      # Increase guaranteed memory
  limits:
    # cpu: no limit  # Keep unlimited for bursting
    memory: 20Gi     # Increase limit (ensure Chrome + ClickHouse < node capacity)
```

**If regular nodes are very constrained:**
```yaml
# In 02-clickhouse-cluster.yaml, anchor template:
resources:
  requests:
    cpu: 300m        # Reduce from 500m
    memory: 1.5Gi    # Reduce from 2Gi
  limits:
    cpu: 500m
    memory: 3Gi
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
