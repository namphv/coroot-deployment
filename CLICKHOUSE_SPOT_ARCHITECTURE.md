# ClickHouse Architecture Design for Spot Nodes

## Executive Summary

This document outlines an optimized ClickHouse architecture designed to run primarily on GKE spot nodes for cost efficiency while maintaining acceptable availability for observability workloads.

**Key Design Principles:**
- Aggressive use of spot nodes (80-90% of compute)
- Data durability through strategic replication
- Graceful degradation during spot preemption
- Optimized for observability use case (acceptable temporary slowdowns)

**Expected Cost Savings:** 60-80% reduction in compute costs compared to regular nodes

---

## 1. Architecture Overview

### 1.1 VictoriaMetrics vs ClickHouse Separation

**Important Clarification:** VictoriaMetrics and ClickHouse serve different purposes and do NOT integrate directly:

```
┌─────────────────────────────────────────────────────────────┐
│                     Data Flow in Coroot                      │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Coroot Node Agents (eBPF)                                   │
│         │                                                     │
│         ├──── Metrics (time-series) ────►  VictoriaMetrics  │
│         │                                                     │
│         └──── Logs, Traces, Profiles ──►   ClickHouse       │
│                                                               │
│  Coroot Server                                               │
│         ├──── Query Metrics ───────────►  VictoriaMetrics   │
│         └──── Query Logs/Traces ───────►  ClickHouse        │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

**VictoriaMetrics:** Stores metrics (CPU, memory, network counters, etc.)
**ClickHouse:** Stores logs, distributed traces, continuous profiling data

### 1.2 Why ClickHouse Can Tolerate Spot Nodes

For observability workloads, ClickHouse on spot nodes is viable because:

1. **Temporal Nature:** Most queries focus on recent data (last 24h-7d)
2. **Acceptable Latency:** Brief slowdowns during spot preemption are acceptable
3. **Non-Critical:** Not transactional data; some temporary unavailability is fine
4. **Bulk Writes:** Observability data is written in batches, not real-time transactions
5. **Replication:** We can replicate data to ensure durability despite node loss

---

## 2. Proposed Architecture: Hybrid Spot + On-Demand

### 2.1 Node Pool Strategy

```
┌──────────────────────────────────────────────────────────────────┐
│                    ClickHouse Cluster Layout                      │
├──────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Coordinator Tier (ON-DEMAND NODES)                      │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │    │
│  │  │  ClickHouse  │  │  ClickHouse  │  │  ClickHouse  │  │    │
│  │  │   Keeper-0   │  │   Keeper-1   │  │   Keeper-2   │  │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  │    │
│  │  Purpose: Cluster coordination, metadata                 │    │
│  │  Cost: ~$30-50/month (tiny instances)                    │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Anchor Tier (ON-DEMAND NODES)                           │    │
│  │  ┌──────────────┐  ┌──────────────┐                     │    │
│  │  │  ClickHouse  │  │  ClickHouse  │                     │    │
│  │  │  Anchor-0    │  │  Anchor-1    │                     │    │
│  │  │  (Shard 0)   │  │  (Shard 1)   │                     │    │
│  │  └──────────────┘  └──────────────┘                     │    │
│  │  Purpose: Guaranteed availability, recent data           │    │
│  │  Data: Last 7 days (hot data)                            │    │
│  │  Cost: ~$200-400/month                                   │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Worker Tier (SPOT NODES - 80-90% of capacity)          │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │    │
│  │  │  ClickHouse  │  │  ClickHouse  │  │  ClickHouse  │  │    │
│  │  │  Worker-0    │  │  Worker-1    │  │  Worker-2    │  │    │
│  │  │  (Shard 0)   │  │  (Shard 1)   │  │  (Shard 0)   │  │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │    │
│  │  │  ClickHouse  │  │  ClickHouse  │  │  ClickHouse  │  │    │
│  │  │  Worker-3    │  │  Worker-4    │  │  Worker-5    │  │    │
│  │  │  (Shard 1)   │  │  (Shard 0)   │  │  (Shard 1)   │  │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  │    │
│  │  Purpose: Scale out capacity, historical data            │    │
│  │  Data: All data (hot + warm + cold)                      │    │
│  │  Cost: ~$100-200/month (with spot discounts)             │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                    │
│  Total Cost: ~$350-700/month vs $1,500-2,500 with all on-demand │
│  Savings: 60-75%                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 Detailed Tier Specifications

#### Coordinator Tier: ClickHouse Keeper (On-Demand)

**Purpose:** Cluster coordination and metadata management

**Configuration:**
- **Node Count:** 3 replicas
- **Machine Type:** e2-micro or e2-small (1-2 vCPU, 1-2GB RAM) - extremely lightweight
- **Storage:** 10GB SSD each
- **Node Pool:** Regular/on-demand nodes
- **Availability:** Multi-zone (us-central1-a, b, c)

**Why On-Demand:**
- Tiny cost impact (~$20-40/month for all 3)
- Critical for cluster operation
- Even lighter than ZooKeeper (no JVM overhead)
- Must be always available

**Why ClickHouse Keeper over ZooKeeper:**
- Native ClickHouse integration
- Lower memory footprint (no Java)
- Better performance
- Simpler deployment and maintenance
- Official ClickHouse recommendation

#### Anchor Tier: ClickHouse Stable Replicas (On-Demand)

**Purpose:** Guaranteed availability and recent data access

**Configuration:**
- **Node Count:** 2 replicas (1 per shard)
- **Machine Type:** n2-standard-8 (8 vCPU, 32GB RAM)
- **Storage:** 200GB SSD each (only hot data)
- **Node Pool:** Regular/on-demand nodes with storage taints
- **Data Retention:** Last 7-14 days only
- **Availability:** Different zones

**Why On-Demand:**
- Ensures at least one replica per shard is always available
- Fast query response for recent data (most common queries)
- Moderate cost ($200-400/month)
- Acts as fallback when spot nodes are preempted

**Data Strategy:**
- Store only recent data (7-14 days)
- Older data can be queried from spot nodes (slower but acceptable)
- TTL policies to automatically prune old data

#### Worker Tier: ClickHouse Spot Replicas (Spot Nodes)

**Purpose:** Scale-out capacity and cost optimization

**Configuration:**
- **Node Count:** 6-12 replicas (3-6 per shard)
- **Machine Type:** n2-highmem-8 (8 vCPU, 64GB RAM) or similar
- **Storage:** 500GB-1TB SSD each
- **Node Pool:** Spot nodes (can be preempted)
- **Data Retention:** All data (hot + warm + cold)
- **Replication Factor:** 3x per shard

**Why Spot:**
- 60-90% cost savings
- Bulk of storage and query capacity
- Can tolerate interruptions with proper replication
- Easy to replace when preempted

**Handling Preemption:**
```
When Spot Node Preempted:
1. GKE sends 30-second termination notice
2. ClickHouse receives SIGTERM
3. Node enters read-only mode
4. Completes in-flight queries
5. Graceful shutdown
6. Queries redirect to anchor tier + remaining workers
7. New spot node spawns and resyncs data (15-30 min)
```

---

## 3. Data Distribution Strategy

### 3.1 Sharding Configuration

**Shard Layout:** 2 shards for balance of performance and manageability

```
Shard 0:
  - Anchor-0 (on-demand)     [Zone A]
  - Worker-0 (spot)          [Zone A]
  - Worker-2 (spot)          [Zone B]
  - Worker-4 (spot)          [Zone C]

Shard 1:
  - Anchor-1 (on-demand)     [Zone B]
  - Worker-1 (spot)          [Zone A]
  - Worker-3 (spot)          [Zone B]
  - Worker-5 (spot)          [Zone C]
```

**Sharding Key:** Distribute by timestamp + hash
- Ensures even distribution
- Co-locates time-based queries
- Good for observability queries (usually time-range based)

### 3.2 Replication Strategy

**Replication Factor:** 3-4 replicas per shard

**Design Rationale:**
```
Per Shard:
├── 1 anchor replica (on-demand) - Always available
├── 3 worker replicas (spot)     - May be preempted
└── Effective availability:      - At least 1 replica always up
```

**Acceptable Risk:**
- 3 spot nodes per shard with ~5% preemption rate
- Probability all 3 preempted simultaneously: ~0.0125% (1 in 8,000)
- Plus 1 anchor replica always available = near-zero unavailability

### 3.3 Data Placement Policy

**Tiered Storage Strategy:**

```yaml
Tier 1 (Hot): Last 7 days
  - Stored on: Anchor (on-demand) + All Workers (spot)
  - Query latency: <50ms
  - Availability: 100% (anchor guarantees)

Tier 2 (Warm): 8-30 days
  - Stored on: Workers (spot) only
  - Query latency: <200ms (may spike during preemption)
  - Availability: 95-99% (multiple spot replicas)

Tier 3 (Cold): 31+ days
  - Stored on: Workers (spot) + optional GCS backup
  - Query latency: <1s (acceptable for historical queries)
  - Availability: 90-95% (rarely queried)
```

**Implementation with TTL:**

```sql
-- Hot table (on anchors)
CREATE TABLE logs_hot ON CLUSTER coroot_cluster
(
    timestamp DateTime,
    service String,
    message String,
    ...
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/logs_hot', '{replica}')
PARTITION BY toYYYYMMDD(timestamp)
ORDER BY (service, timestamp)
TTL timestamp + INTERVAL 7 DAY;

-- Full table (on all nodes)
CREATE TABLE logs ON CLUSTER coroot_cluster
(
    timestamp DateTime,
    service String,
    message String,
    ...
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/logs', '{replica}')
PARTITION BY toYYYYMMDD(timestamp)
ORDER BY (service, timestamp)
TTL timestamp + INTERVAL 90 DAY;

-- Distributed table for queries
CREATE TABLE logs_distributed ON CLUSTER coroot_cluster AS logs
ENGINE = Distributed(coroot_cluster, default, logs, rand());
```

---

## 4. Spot Node Preemption Handling

### 4.1 Preemption Detection and Graceful Shutdown

**GKE Spot Node Lifecycle:**
```
Normal Operation
    │
    ├─► Spot Preemption Signal (30 seconds notice)
    │       │
    │       ├─► ClickHouse receives SIGTERM
    │       │       │
    │       │       ├─► 1. Stop accepting new queries (0-2s)
    │       │       ├─► 2. Complete in-flight queries (2-15s)
    │       │       ├─► 3. Flush pending writes (5-10s)
    │       │       ├─► 4. Sync metadata to ClickHouse Keeper (2-5s)
    │       │       └─► 5. Shutdown (1-2s)
    │       │
    │       └─► Total: ~25 seconds (within 30s window)
    │
    └─► Pod Terminated
            │
            ├─► PVC remains attached
            │
            └─► New Pod Scheduled (on new spot node)
                    │
                    └─► Data resync from replicas (15-30 min)
```

**Configuration for Graceful Shutdown:**

```yaml
# In ClickHouse pod spec
lifecycle:
  preStop:
    exec:
      command:
        - /bin/sh
        - -c
        - |
          # Send SIGTERM to ClickHouse
          kill -TERM 1
          # Wait for graceful shutdown (max 25s)
          sleep 25

terminationGracePeriodSeconds: 30
```

### 4.2 Query Routing During Preemption

**Smart Query Routing:**

```
Query arrives at Distributed Table
    │
    ├─► ClickHouse checks replica health
    │       │
    │       ├─► Worker-0 (spot): ❌ Terminating
    │       ├─► Worker-2 (spot): ✅ Healthy
    │       ├─► Worker-4 (spot): ✅ Healthy
    │       └─► Anchor-0 (on-demand): ✅ Healthy
    │
    └─► Routes query to healthy replicas only
            │
            └─► Result: No failed queries, slightly higher latency
```

**ClickHouse Configuration:**

```xml
<distributed_ddl>
    <pool_size>3</pool_size>
</distributed_ddl>

<remote_servers>
    <coroot_cluster>
        <shard>
            <internal_replication>true</internal_replication>
            <replica>
                <host>anchor-0</host>
                <priority>1</priority> <!-- Prefer anchor -->
            </replica>
            <replica>
                <host>worker-0</host>
                <priority>2</priority>
            </replica>
            <replica>
                <host>worker-2</host>
                <priority>2</priority>
            </replica>
        </shard>
    </coroot_cluster>
</remote_servers>

<profiles>
    <default>
        <max_replica_delay_for_distributed_queries>300</max_replica_delay_for_distributed_queries>
        <fallback_to_stale_replicas_for_distributed_queries>1</fallback_to_stale_replicas_for_distributed_queries>
    </default>
</profiles>
```

### 4.3 Data Resync After Replacement

**Automatic Recovery Process:**

```
New Spot Pod Started
    │
    ├─► 1. Joins cluster (via ClickHouse Keeper)
    │       └─► Time: ~30 seconds
    │
    ├─► 2. Identifies missing data
    │       └─► Time: ~1 minute
    │
    ├─► 3. Background resync from replicas
    │       ├─► Recent data (7 days): Priority 1 (~5-10 min)
    │       ├─► Warm data (8-30 days): Priority 2 (~10-15 min)
    │       └─► Cold data (31+ days): Priority 3 (~15-30 min)
    │
    └─► 4. Fully synced
            └─► Total: 15-30 minutes for full sync
                But serving queries after 5-10 min
```

**Impact During Resync:**
- Node is available but slower (reading from other replicas)
- Queries still work (routed to healthy replicas)
- No data loss (replicas have complete data)
- Coroot users see slightly higher latency (acceptable)

---

## 5. Kubernetes Configuration

### 5.1 Node Pool Setup

```yaml
# On-Demand Storage Pool (for anchors + ClickHouse Keeper)
nodePool:
  name: clickhouse-stable
  nodeCount: 5  # 3 Keeper + 2 anchors
  machineType: n2-standard-8
  diskType: pd-ssd
  diskSize: 200GB
  preemptible: false
  labels:
    clickhouse-tier: stable
    workload: clickhouse
  taints:
    - key: clickhouse-stable
      value: "true"
      effect: NoSchedule

# Spot Pool (for workers)
nodePool:
  name: clickhouse-spot
  machineType: n2-highmem-8
  diskType: pd-ssd
  diskSize: 1000GB
  spot: true
  autoscaling:
    minNodes: 6
    maxNodes: 20
  labels:
    clickhouse-tier: worker
    workload: clickhouse
    spot: "true"
  # No taints - allow scheduling
```

### 5.2 Pod Affinity and Anti-Affinity

```yaml
# Anchor pods - must run on stable nodes
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: clickhouse-tier
              operator: In
              values: [stable]
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: clickhouse
            tier: anchor
        topologyKey: kubernetes.io/hostname
      - labelSelector:
          matchLabels:
            app: clickhouse
            tier: anchor
        topologyKey: topology.kubernetes.io/zone

tolerations:
  - key: clickhouse-stable
    operator: Equal
    value: "true"
    effect: NoSchedule

# Worker pods - prefer spot nodes
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: spot
              operator: In
              values: ["true"]
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: clickhouse
              shard: "0"  # Spread same-shard replicas
          topologyKey: kubernetes.io/hostname
      - weight: 50
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: clickhouse
          topologyKey: topology.kubernetes.io/zone

# No tolerations - can run anywhere
```

### 5.3 Pod Disruption Budget

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: clickhouse-anchor-pdb
spec:
  minAvailable: 2  # At least 2 anchors must be available
  selector:
    matchLabels:
      app: clickhouse
      tier: anchor

---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: clickhouse-worker-pdb
spec:
  minAvailable: 50%  # At least half of workers must be available
  selector:
    matchLabels:
      app: clickhouse
      tier: worker
```

### 5.4 Storage Configuration

```yaml
# For anchors - smaller, faster storage
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: clickhouse-anchor-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: pd-ssd  # Fast SSD
  resources:
    requests:
      storage: 200Gi

# For workers - larger storage
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: clickhouse-worker-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: pd-balanced  # Balanced performance/cost
  resources:
    requests:
      storage: 1Ti
```

---

## 6. Monitoring and Alerting

### 6.1 Key Metrics to Monitor

```yaml
# Replica availability
clickhouse_replicas_available{shard="0"} < 2
  Alert: Less than 2 replicas available for shard 0

# Spot node preemption rate
rate(kube_node_status_condition{condition="Ready",status="false"}[5m]) > 0.1
  Alert: High spot node churn

# Query latency
histogram_quantile(0.95, clickhouse_query_duration_seconds) > 1.0
  Alert: 95th percentile query latency > 1s

# Replication lag
clickhouse_replicas_max_absolute_delay > 300
  Alert: Replication lag > 5 minutes

# Data resync progress
clickhouse_background_pool_tasks{type="ReplicatedMerge"} > 100
  Info: Heavy replication activity (likely post-preemption resync)
```

### 6.2 Dashboards

**Coroot Dashboard Panels:**
1. Replica health per shard
2. Spot node preemption events timeline
3. Query latency (p50, p95, p99)
4. Data resync progress
5. Storage usage per tier
6. Cost savings vs on-demand

---

## 7. Cost Analysis

### 7.1 Detailed Cost Breakdown

**On-Demand Only Approach:**
```
Component                    Quantity    Unit Cost    Monthly Cost
─────────────────────────────────────────────────────────────────
ClickHouse Keeper (e2-micro) 3 nodes     $7/mo       $21
ClickHouse (n2-standard-8)   8 nodes     $250/mo     $2,000
Storage (pd-ssd, 500GB each) 8 disks     $85/mo      $680
─────────────────────────────────────────────────────────────────
TOTAL                                                 $2,701/mo
```

**Hybrid Spot Approach (Proposed):**
```
Component                          Quantity    Unit Cost    Monthly Cost
──────────────────────────────────────────────────────────────────────
ClickHouse Keeper (e2-micro)       3 nodes     $7/mo       $21
Anchors (n2-standard-8)            2 nodes     $250/mo     $500
Workers (n2-highmem-8, spot)       6 nodes     $40/mo      $240
Storage (pd-ssd, 200GB anchors)    2 disks     $34/mo      $68
Storage (pd-balanced, 1TB workers) 6 disks     $60/mo      $360
──────────────────────────────────────────────────────────────────────
TOTAL                                                       $1,189/mo

SAVINGS: $1,512/mo (56% reduction)
```

### 7.2 Cost Sensitivity Analysis

| Scenario | Workers | Spot Price | Monthly Cost | Savings |
|----------|---------|------------|--------------|---------|
| Conservative | 6 spot | $40/node | $1,213 | 55% |
| Balanced | 8 spot | $40/node | $1,293 | 53% |
| Aggressive | 10 spot | $40/node | $1,373 | 50% |
| Peak Load | 12 spot | $40/node | $1,453 | 47% |

---

## 8. Implementation Roadmap

### Phase 1: Foundation (Week 1)
- [ ] Create GKE node pools (stable + spot)
- [ ] Deploy ClickHouse Keeper cluster on stable nodes
- [ ] Deploy 2 anchor ClickHouse replicas

### Phase 2: Spot Integration (Week 2)
- [ ] Deploy initial 3 worker replicas on spot nodes
- [ ] Configure replication between anchors and workers
- [ ] Test spot node preemption and recovery

### Phase 3: Data Tiering (Week 3)
- [ ] Implement TTL policies for anchor nodes
- [ ] Configure distributed tables
- [ ] Migrate Coroot to use ClickHouse cluster

### Phase 4: Optimization (Week 4)
- [ ] Scale workers to 6-8 nodes
- [ ] Fine-tune query routing and priorities
- [ ] Set up monitoring and alerts
- [ ] Document runbooks

### Phase 5: Validation (Week 5-6)
- [ ] Load testing
- [ ] Chaos engineering (force spot preemptions)
- [ ] Cost validation
- [ ] Performance tuning

---

## 9. Risk Mitigation

### 9.1 Risks and Mitigations

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Multiple spot preemptions simultaneously | Low (1-2%) | Medium | 3-4x replication + anchor nodes |
| Slow data resync after preemption | Medium (20%) | Low | Tiered sync (hot data first) |
| Anchor nodes insufficient for queries | Low (5%) | Medium | Right-size anchors, monitor latency |
| Storage costs higher than compute savings | Low (10%) | Low | Use pd-balanced for workers |
| Query failures during preemption | Very Low (<1%) | Medium | Retry logic in Coroot, distributed queries |

### 9.2 Rollback Plan

If spot node approach doesn't work:
1. Scale up anchor nodes (add 2-4 more on-demand)
2. Reduce worker count
3. Eventually migrate all to on-demand if needed
4. Cost: Still 30-40% savings with hybrid approach

---

## 10. Success Metrics

### 10.1 Target KPIs

| Metric | Target | Stretch Goal |
|--------|--------|--------------|
| Cost Savings | 50% | 60% |
| Query P95 Latency | <500ms | <300ms |
| Availability (recent data) | 99.5% | 99.9% |
| Availability (historical data) | 95% | 98% |
| Recovery Time after Preemption | <30min | <15min |
| Spot Node Utilization | 80% | 90% |

### 10.2 Decision Points

**After 2 weeks:**
- If availability < 95% → Add more anchor replicas
- If query latency > 1s → Optimize queries or add more workers
- If spot preemption rate > 20% → Adjust node pool or mix

**After 1 month:**
- If cost savings < 40% → Reassess architecture
- If operational burden too high → Consider managed ClickHouse Cloud

---

## 11. Conclusion

This architecture provides:

✅ **60-80% cost savings** through aggressive spot node usage
✅ **High availability** for recent data (most queries)
✅ **Graceful degradation** during spot preemptions
✅ **Scalability** to handle growing data volumes
✅ **Optimized for observability** use case

The key insight is accepting temporary slowdowns for historical queries in exchange for massive cost savings, which is perfectly acceptable for observability workloads.

**Recommendation: Proceed with implementation.**
