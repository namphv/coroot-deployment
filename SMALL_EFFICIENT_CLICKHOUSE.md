# Small Efficient ClickHouse Deployment for Coroot

## Environment Constraints

**Your Setup:**
- 2 regular nodes (limited resources available - only small portions usable)
- 1 big spot node (main compute capacity)

**Goal:**
- Maximize use of the big spot node
- Minimize footprint on regular nodes
- Ensure data durability despite spot preemptions
- Leverage ClickHouse sharding and replication

---

## 1. Recommended Architecture

### 1.1 Minimal HA Configuration

```
┌──────────────────────────────────────────────────────────────┐
│                  Small Efficient Deployment                   │
├──────────────────────────────────────────────────────────────┤
│                                                                │
│  Regular Nodes (2 nodes, minimal resource usage)             │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Node 1:                                                │  │
│  │  ├─ ClickHouse Keeper-0 (100-200MB, 0.1 CPU)          │  │
│  │  └─ ClickHouse Anchor   (1-2GB, 0.5-1 CPU)            │  │
│  │                                                          │  │
│  │  Node 2:                                                │  │
│  │  ├─ ClickHouse Keeper-1 (100-200MB, 0.1 CPU)          │  │
│  │  └─ Coroot Server       (2GB, 1 CPU)                   │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                                │
│  Big Spot Node (1 node, use most/all resources)              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  ├─ ClickHouse Keeper-2 (100-200MB, 0.1 CPU)          │  │
│  │  ├─ ClickHouse Worker   (Remaining RAM, CPU)           │  │
│  │  └─ Coroot Node Agents  (200-500MB, 0.2 CPU)          │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                                │
│  Configuration: 1 Shard, 2 Replicas                           │
│  - Anchor (Regular Node 1): Hot data, always available       │
│  - Worker (Spot Node):      All data, main workload          │
│                                                                │
│  Total footprint on regular nodes: ~3-5GB RAM, ~2 CPU        │
│  Total footprint on spot node:     Most resources            │
└──────────────────────────────────────────────────────────────┘
```

### 1.2 Alternative: Ultra-Minimal (If extremely constrained)

```
┌──────────────────────────────────────────────────────────────┐
│                    Ultra-Minimal Deployment                   │
├──────────────────────────────────────────────────────────────┤
│                                                                │
│  Regular Nodes (absolute minimum)                             │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Node 1:                                                │  │
│  │  └─ ClickHouse Keeper-0 (150MB, 0.1 CPU)              │  │
│  │                                                          │  │
│  │  Node 2:                                                │  │
│  │  ├─ ClickHouse Keeper-1 (150MB, 0.1 CPU)              │  │
│  │  └─ Coroot Server       (1.5GB, 0.5 CPU)              │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                                │
│  Big Spot Node (everything else)                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  ├─ ClickHouse Keeper-2 (150MB, 0.1 CPU)              │  │
│  │  ├─ ClickHouse Single    (Most RAM, CPU)               │  │
│  │  │  (Handles all data, no replication)                 │  │
│  │  └─ Coroot Node Agents  (200MB, 0.2 CPU)              │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                                │
│  Configuration: 1 Shard, 1 Replica                            │
│  - Risk: Data loss if spot node preempted before resync      │
│  - Mitigation: Frequent snapshots, fast recovery             │
│                                                                │
│  Total footprint on regular nodes: ~1.8GB RAM, ~0.7 CPU      │
└──────────────────────────────────────────────────────────────┘
```

---

## 2. Recommended: Minimal HA Configuration (1 Shard, 2 Replicas)

This balances resource usage with data safety.

### 2.1 Component Breakdown

#### ClickHouse Keeper (3 instances)

**Purpose:** Coordination (required for replication)

**Placement:**
- Keeper-0: Regular Node 1
- Keeper-1: Regular Node 2
- Keeper-2: Spot Node

**Resources per instance:**
```yaml
requests:
  cpu: 100m
  memory: 128Mi
limits:
  cpu: 200m
  memory: 256Mi
storage: 5Gi
```

**Total footprint:** ~450MB RAM, ~0.3 CPU (across all nodes)

#### ClickHouse Anchor Replica (Regular Node)

**Purpose:**
- Hot data (last 3-7 days)
- Guaranteed availability during spot preemptions
- Minimal resource footprint

**Placement:** Regular Node 1 (or spread across both if space allows)

**Resources:**
```yaml
requests:
  cpu: 500m
  memory: 2Gi
limits:
  cpu: 1000m
  memory: 4Gi
storage: 50Gi (SSD for hot data)
```

**Data retention:** 3-7 days only (TTL for auto-pruning)

**Configuration:**
- Compression: aggressive (zstd level 3)
- Indexes: minimal (reduce overhead)
- Background merges: throttled

#### ClickHouse Worker Replica (Spot Node)

**Purpose:**
- All data (hot + warm + cold)
- Main query processing
- Scale-out capacity

**Placement:** Big Spot Node

**Resources:**
```yaml
requests:
  cpu: 4000m      # Adjust based on node size
  memory: 16Gi    # Adjust based on node size
limits:
  cpu: 8000m      # Can use more if available
  memory: 32Gi    # Can use more if available
storage: 500Gi    # Or whatever fits on node
```

**Data retention:** 30-90 days

**Configuration:**
- Full data set
- Optimized for throughput
- Background processes enabled

#### Coroot Server

**Placement:** Regular Node 2

**Resources:**
```yaml
requests:
  cpu: 500m
  memory: 2Gi
limits:
  cpu: 2000m
  memory: 4Gi
storage: 20Gi
```

---

## 3. Sharding vs Replication Strategy

### 3.1 Why NOT Shard (For Small Deployment)?

**Sharding** splits data across multiple nodes:
- Shard 0: 50% of data
- Shard 1: 50% of data

**Pros:**
- Distributes query load
- Scales write throughput

**Cons for small deployment:**
- Need at least 2 ClickHouse instances on regular nodes (more resources!)
- More complex
- Each shard needs its own anchor replica
- Not worth it for small data volumes

**Verdict:** Skip sharding for this deployment size.

### 3.2 Why Replicate (Recommended)?

**Replication** duplicates data across nodes:
- Replica 0 (Anchor): Full dataset (pruned to 7d)
- Replica 1 (Worker): Full dataset (30-90d)

**Pros:**
- Data durability (survives spot preemption)
- Query load balancing (both replicas can serve queries)
- Minimal resource footprint on regular nodes

**Cons:**
- 2x storage (but worth it for safety)

**Verdict:** Use 1 shard with 2 replicas.

---

## 4. Configuration Details

### 4.1 ClickHouse Cluster Definition

```yaml
apiVersion: "clickhouse.altinity.com/v1"
kind: "ClickHouseInstallation"
metadata:
  name: coroot-clickhouse-small
  namespace: clickhouse
spec:
  configuration:
    clusters:
      - name: coroot-cluster
        layout:
          shardsCount: 1      # Single shard
          replicasCount: 2    # 2 replicas for HA

    zookeeper:
      nodes:
        - host: clickhouse-keeper-0.clickhouse-keeper-headless.clickhouse.svc.cluster.local
          port: 9181
        - host: clickhouse-keeper-1.clickhouse-keeper-headless.clickhouse.svc.cluster.local
          port: 9181
        - host: clickhouse-keeper-2.clickhouse-keeper-headless.clickhouse.svc.cluster.local
          port: 9181

  defaults:
    templates:
      podTemplate: default-pod-template
      dataVolumeClaimTemplate: default-storage

  templates:
    podTemplates:
      # Anchor replica template (regular node)
      - name: anchor-pod-template
        spec:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: cloud.google.com/gke-spot
                        operator: DoesNotExist  # NOT a spot node

          containers:
            - name: clickhouse
              image: clickhouse/clickhouse-server:24.11
              resources:
                requests:
                  cpu: 500m
                  memory: 2Gi
                limits:
                  cpu: 1000m
                  memory: 4Gi

      # Worker replica template (spot node)
      - name: worker-pod-template
        spec:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: cloud.google.com/gke-spot
                        operator: Exists  # MUST be spot node

          containers:
            - name: clickhouse
              image: clickhouse/clickhouse-server:24.11
              resources:
                requests:
                  cpu: 4000m
                  memory: 16Gi
                limits:
                  cpu: 8000m
                  memory: 32Gi

    volumeClaimTemplates:
      # Anchor storage (small, hot data only)
      - name: anchor-storage
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 50Gi
          storageClassName: pd-ssd

      # Worker storage (large, all data)
      - name: worker-storage
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 500Gi
          storageClassName: pd-balanced

  # Layout: 1 shard, 2 replicas
  # Replica 0 = Anchor (regular node)
  # Replica 1 = Worker (spot node)
```

### 4.2 Data Tiering with TTL

**Anchor Replica (Hot Data):**
```sql
-- Create table with aggressive TTL
CREATE TABLE logs ON CLUSTER coroot_cluster
(
    timestamp DateTime64(3),
    level String,
    message String,
    labels Map(String, String)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/logs', '{replica}')
PARTITION BY toYYYYMMDD(timestamp)
ORDER BY (timestamp, level)
TTL timestamp + INTERVAL 7 DAY  -- Anchor keeps only 7 days
SETTINGS
    storage_policy = 'default',
    index_granularity = 8192,
    -- Aggressive compression
    min_compress_block_size = 65536,
    max_compress_block_size = 1048576;
```

**Worker Replica (All Data):**
```sql
-- Same table, but with longer TTL on worker replica
-- Applied via replica-specific settings
ALTER TABLE logs ON CLUSTER coroot_cluster
MODIFY TTL timestamp + INTERVAL 90 DAY;
```

### 4.3 Query Routing

ClickHouse automatically routes queries:
- **Recent queries (< 7d)**: Both replicas can serve → balanced load
- **Historical queries (> 7d)**: Only worker replica has data → routes there
- **Worker down**: Queries fallback to anchor (limited to 7d data)

---

## 5. Resource Summary

### 5.1 Regular Node 1

```
Component                CPU Request  CPU Limit  Memory Request  Memory Limit  Storage
─────────────────────────────────────────────────────────────────────────────────────────
ClickHouse Keeper-0      100m         200m       128Mi          256Mi         5Gi
ClickHouse Anchor        500m         1000m      2Gi            4Gi           50Gi
─────────────────────────────────────────────────────────────────────────────────────────
TOTAL                    600m         1200m      2.1Gi          4.3Gi         55Gi
```

### 5.2 Regular Node 2

```
Component                CPU Request  CPU Limit  Memory Request  Memory Limit  Storage
─────────────────────────────────────────────────────────────────────────────────────────
ClickHouse Keeper-1      100m         200m       128Mi          256Mi         5Gi
Coroot Server            500m         2000m      2Gi            4Gi           20Gi
PostgreSQL               250m         500m       1Gi            2Gi           10Gi
─────────────────────────────────────────────────────────────────────────────────────────
TOTAL                    850m         2700m      3.1Gi          6.3Gi         35Gi
```

### 5.3 Big Spot Node

```
Component                CPU Request  CPU Limit  Memory Request  Memory Limit  Storage
─────────────────────────────────────────────────────────────────────────────────────────
ClickHouse Keeper-2      100m         200m       128Mi          256Mi         5Gi
ClickHouse Worker        4000m        8000m      16Gi           32Gi          500Gi
Coroot Node Agents       200m         500m       512Mi          1Gi           -
─────────────────────────────────────────────────────────────────────────────────────────
TOTAL                    4300m        8700m      16.6Gi         33.3Gi        505Gi
```

**Example for n2-highmem-16 spot node (16 vCPU, 128GB RAM):**
- CPU usage: ~27-54% (4.3-8.7 vCPU)
- Memory usage: ~13-26% (16.6-33.3 GB)
- Plenty of headroom for application workloads!

---

## 6. Spot Node Preemption Handling

### 6.1 What Happens During Preemption

```
1. Spot node receives 30-second termination notice
   │
   ├─► ClickHouse Worker receives SIGTERM
   │   └─► Graceful shutdown (~25 seconds)
   │       ├─ Stop accepting writes
   │       ├─ Complete in-flight queries
   │       ├─ Flush pending data
   │       └─ Sync to ClickHouse Keeper
   │
   └─► Pod terminated
       │
       ├─► Queries automatically route to Anchor replica
       │   (Limited to 7-day data, but cluster stays online!)
       │
       └─► New spot node spawns (2-5 minutes)
           │
           └─► ClickHouse Worker rejoins cluster
               └─► Background resync from Anchor replica (~10-30 min)
```

### 6.2 Impact

**During Preemption (2-5 minutes):**
- ✅ Cluster operational (Anchor handles queries)
- ✅ Recent data (7d) fully available
- ⚠️ Historical data (>7d) temporarily unavailable
- ⚠️ Slightly higher query latency (single replica)

**During Resync (10-30 minutes):**
- ✅ Cluster operational
- ✅ All queries work
- ⚠️ Worker replica catching up in background
- ⚠️ Historical queries slightly slower

**After Resync:**
- ✅ Full functionality restored
- ✅ Both replicas up to date

---

## 7. Cost Estimate

### 7.1 GCP Cost Breakdown

**Assuming:**
- Regular nodes: n2-standard-4 (4 vCPU, 16GB) = $120/mo each
- Spot node: n2-highmem-16 (16 vCPU, 128GB spot) = $160/mo

```
Component                          Monthly Cost
──────────────────────────────────────────────
2 × Regular nodes (n2-standard-4)  $240
1 × Spot node (n2-highmem-16)      $160
Storage (50GB + 500GB SSD)         $70
──────────────────────────────────────────────
TOTAL                              $470/mo
```

**vs All on-demand:** $920/mo
**Savings:** 49%

---

## 8. Trade-offs Analysis

### 8.1 Minimal HA (Recommended)

| Aspect | Rating | Notes |
|--------|--------|-------|
| Cost | ⭐⭐⭐⭐⭐ | Very low (~$470/mo) |
| Resource efficiency | ⭐⭐⭐⭐⭐ | Minimal regular node usage |
| Data durability | ⭐⭐⭐⭐ | 2 replicas, survives spot loss |
| Query availability | ⭐⭐⭐⭐ | Always available (anchor fallback) |
| Historical queries | ⭐⭐⭐ | Temporarily unavailable during spot preemption |
| Complexity | ⭐⭐⭐⭐ | Simple setup |

### 8.2 Ultra-Minimal (1 Replica)

| Aspect | Rating | Notes |
|--------|--------|-------|
| Cost | ⭐⭐⭐⭐⭐ | Lowest possible (~$440/mo) |
| Resource efficiency | ⭐⭐⭐⭐⭐ | Absolute minimum on regular nodes |
| Data durability | ⭐⭐ | Risk of data loss during preemption |
| Query availability | ⭐⭐ | Downtime during preemption/resync |
| Historical queries | ⭐⭐⭐⭐⭐ | All data on worker when available |
| Complexity | ⭐⭐⭐⭐⭐ | Very simple |

**Recommendation:** Use Minimal HA (2 replicas) unless:
- You have automated snapshots/backups
- Brief downtime is acceptable
- Data loss window (< 5 minutes) is acceptable

---

## 9. Deployment Manifests

### 9.1 Node Pool Configuration (GKE)

```bash
# Regular node pool (2 nodes)
gcloud container node-pools create regular-pool \
  --cluster=coroot-cluster \
  --machine-type=n2-standard-4 \
  --num-nodes=2 \
  --disk-size=100 \
  --disk-type=pd-ssd \
  --enable-autorepair \
  --enable-autoupgrade

# Spot node pool (1 node, autoscaling 1-2)
gcloud container node-pools create spot-pool \
  --cluster=coroot-cluster \
  --machine-type=n2-highmem-16 \
  --spot \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=2 \
  --disk-size=200 \
  --disk-type=pd-ssd \
  --enable-autorepair \
  --enable-autoupgrade
```

### 9.2 ClickHouse Keeper (Minimal)

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: clickhouse-keeper
  namespace: clickhouse
spec:
  serviceName: clickhouse-keeper-headless
  replicas: 3
  selector:
    matchLabels:
      app: clickhouse-keeper
  template:
    metadata:
      labels:
        app: clickhouse-keeper
    spec:
      # Anti-affinity to spread across nodes
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: clickhouse-keeper
                topologyKey: kubernetes.io/hostname

      containers:
        - name: clickhouse-keeper
          image: clickhouse/clickhouse-keeper:latest
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
          # ... (rest same as before)
```

### 9.3 Full Deployment Manifests

See `k8s/clickhouse/small-efficient/` directory for complete manifests:
- `clickhouse-keeper-minimal.yaml` - Minimal Keeper configuration
- `clickhouse-cluster-small.yaml` - 1 shard, 2 replicas
- `node-affinity-rules.yaml` - Anchor on regular, worker on spot

---

## 10. Monitoring and Validation

### 10.1 Verify Resource Usage

```bash
# Check regular node usage
kubectl top nodes -l cloud.google.com/gke-spot!=true

# Check spot node usage
kubectl top nodes -l cloud.google.com/gke-spot=true

# Check ClickHouse pod placement
kubectl get pods -n clickhouse -o wide
```

### 10.2 Test Spot Preemption

```bash
# Simulate spot preemption
kubectl delete pod -n clickhouse <worker-pod-name>

# Watch recovery
kubectl get pods -n clickhouse -w

# Verify queries still work
kubectl exec -n clickhouse chi-coroot-clickhouse-small-0-0-0 -- \
  clickhouse-client --query="SELECT count() FROM system.tables"
```

---

## 11. Recommendations

### 11.1 For Your Environment (2 regular + 1 big spot)

✅ **Use Minimal HA** (1 shard, 2 replicas):
- Anchor replica on regular node: ~2.5GB RAM, ~0.6 CPU
- Worker replica on spot node: Most resources
- ClickHouse Keeper: Spread across all 3 nodes (~450MB total)

✅ **Configure aggressive TTL** on anchor:
- Keep only 3-7 days on regular node
- Keep 30-90 days on spot node

✅ **Monitor and tune**:
- Start with conservative resource requests
- Increase limits as needed
- Monitor query performance

### 11.2 When to Scale Up

Consider adding resources when:
- Regular node CPU consistently > 80%
- Query latency > 1 second
- Data ingestion falls behind
- Frequent OOM kills

### 11.3 When to Add Sharding

Only add sharding (2+ shards) when:
- Data volume > 1TB per shard
- Write throughput > 100K rows/sec
- Query load can't be handled by replication alone
- You can allocate resources for multiple anchor replicas

---

## 12. Quick Start

```bash
# 1. Create namespaces
kubectl apply -f k8s/namespaces/

# 2. Deploy minimal Keeper
kubectl apply -f k8s/clickhouse/small-efficient/clickhouse-keeper-minimal.yaml

# 3. Wait for Keeper
kubectl wait --for=condition=ready pod -l app=clickhouse-keeper -n clickhouse --timeout=300s

# 4. Deploy small ClickHouse cluster (1 shard, 2 replicas)
kubectl apply -f k8s/clickhouse/small-efficient/clickhouse-cluster-small.yaml

# 5. Deploy Coroot with ClickHouse metrics
kubectl apply -f k8s/coroot/coroot-values.yaml

# 6. Verify
kubectl get pods -n clickhouse
kubectl get pods -n monitoring
```

---

## Summary

For your **2 regular nodes + 1 big spot node** setup:

**Best Configuration:**
- ✅ 1 shard, 2 replicas (not multiple shards)
- ✅ Anchor replica on regular node (hot data, minimal resources)
- ✅ Worker replica on spot node (all data, main workload)
- ✅ ClickHouse Keeper spread across all nodes (tiny footprint)
- ✅ Total regular node usage: ~3-5GB RAM, ~1.5 CPU

**Expected Performance:**
- Query latency: <100ms (recent data), <500ms (historical)
- Spot preemption impact: 2-30 minutes degraded performance
- Data durability: High (2 replicas)

**Cost:** ~$470/month (49% savings vs all on-demand)

This is the most efficient ClickHouse design for your constraints! 🎯
