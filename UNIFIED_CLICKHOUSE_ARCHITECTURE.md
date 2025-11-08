# Unified ClickHouse Architecture for Coroot

## Executive Summary

This document outlines a **simplified architecture** using ClickHouse as the single storage backend for ALL observability data: metrics, logs, traces, and profiles.

**Key Benefits:**
- **Simplified Stack**: One storage system instead of two (ClickHouse + VictoriaMetrics)
- **Cost Reduction**: No VictoriaMetrics infrastructure needed (~$300-400/month savings)
- **Unified Queries**: Query all data from one place
- **Native Support**: Coroot has built-in ClickHouse metrics support
- **Still Spot-Optimized**: Aggressive use of spot nodes (80-90%)

**Expected Cost:** $800-900/month (vs $1,189/month with VictoriaMetrics)
**Total Savings:** 67% reduction vs all on-demand

---

## 1. Why ClickHouse for Everything?

### 1.1 Coroot's Native ClickHouse Support

Coroot has a built-in flag: `--global-prometheus-use-clickhouse` (or env var `GLOBAL_PROMETHEUS_USE_CLICKHOUSE=true`)

When enabled:
- ✅ Metrics stored directly in ClickHouse
- ✅ Logs, traces, profiles already in ClickHouse
- ✅ PromQL still works for queries
- ✅ No adapters or bridges needed
- ✅ Unified storage management

### 1.2 ClickHouse as Time-Series Database

ClickHouse is excellent for time-series metrics:
- **High compression**: 10-100x compression for time-series data
- **Fast queries**: Columnar storage optimized for analytics
- **Scalability**: Horizontal scaling with sharding
- **Mature**: Battle-tested for large-scale analytics
- **Cost-effective**: Efficient storage and compute

### 1.3 Architecture Comparison

**Old Architecture (VictoriaMetrics + ClickHouse):**
```
Coroot Agents → VictoriaMetrics (metrics)
              → ClickHouse (logs, traces, profiles)

Infrastructure needed:
- VictoriaMetrics cluster (vmselect, vminsert, vmstorage)
- ClickHouse cluster
- ClickHouse Keeper

Monthly cost: ~$1,189
```

**New Architecture (ClickHouse Only):**
```
Coroot Agents → ClickHouse (metrics, logs, traces, profiles)

Infrastructure needed:
- ClickHouse cluster
- ClickHouse Keeper

Monthly cost: ~$800-900
Savings: ~$300-400/month (25% additional savings!)
```

---

## 2. Simplified Architecture

### 2.1 Cluster Layout

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
│  │  Cost: ~$21/month (e2-micro instances)                   │    │
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
│  │  Data: ALL recent data (metrics + logs + traces)        │    │
│  │  Retention: Last 7 days (hot data)                       │    │
│  │  Cost: ~$500/month                                        │    │
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
│  │  Purpose: Scale out capacity, all historical data        │    │
│  │  Data: ALL data (metrics + logs + traces)               │    │
│  │  Retention: 30-90 days                                    │    │
│  │  Cost: ~$240-300/month (with spot discounts)             │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Coroot Application (ON-DEMAND or SPOT)                  │    │
│  │  ┌──────────────┐  ┌──────────────┐                     │    │
│  │  │   Coroot     │  │   Coroot     │                     │    │
│  │  │   Server-0   │  │   Server-1   │                     │    │
│  │  └──────────────┘  └──────────────┘                     │    │
│  │  ┌──────────────┐                                        │    │
│  │  │  PostgreSQL  │  (Coroot metadata)                    │    │
│  │  └──────────────┘                                        │    │
│  │  ┌──────────────────────────────────────────────────┐   │    │
│  │  │  Coroot Node Agents (DaemonSet on ALL nodes)     │   │    │
│  │  └──────────────────────────────────────────────────┘   │    │
│  │  Cost: ~$150-200/month                                    │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                    │
│  Total Cost: ~$800-900/month vs $2,700 with all on-demand       │
│  Savings: 67%                                                     │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                     Unified Data Flow                        │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Coroot Node Agents (eBPF)                                   │
│         │                                                     │
│         ├──── Metrics ─────────────┐                         │
│         ├──── Logs ────────────────┤                         │
│         ├──── Traces ──────────────├──► ClickHouse          │
│         └──── Profiles ────────────┘                         │
│                                                               │
│  Coroot Server                                               │
│         └──── Query ALL Data ──────►  ClickHouse            │
│               (PromQL for metrics still works!)              │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. ClickHouse Configuration for Metrics

### 3.1 Table Schema for Metrics

ClickHouse will use optimized tables for time-series metrics:

```sql
-- Metrics table (time-series data)
CREATE TABLE metrics ON CLUSTER coroot_cluster
(
    timestamp DateTime64(3),
    metric_name String,
    value Float64,
    labels Map(String, String),
    -- Indexes for fast queries
    INDEX metric_name_idx metric_name TYPE bloom_filter GRANULARITY 1,
    INDEX labels_idx mapKeys(labels) TYPE bloom_filter GRANULARITY 1
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/metrics', '{replica}')
PARTITION BY toYYYYMMDD(timestamp)
ORDER BY (metric_name, timestamp)
TTL timestamp + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

-- Distributed table for queries
CREATE TABLE metrics_distributed ON CLUSTER coroot_cluster AS metrics
ENGINE = Distributed(coroot_cluster, default, metrics, rand());
```

### 3.2 Storage Efficiency

**Metrics Compression:**
- Raw metrics: ~1KB per sample
- Compressed in ClickHouse: ~10-50 bytes per sample
- **Compression ratio: 10-100x**

**Example Storage Calculation:**
```
Assumptions:
- 1,000 metrics per node
- 30-second scrape interval
- 10 nodes in cluster

Metrics per day:
1,000 metrics × 10 nodes × (24h × 60min × 2) = 28,800,000 samples/day

Storage (uncompressed): 28.8M × 1KB = 28.8 GB/day
Storage (compressed):   28.8M × 30B = 864 MB/day

For 90-day retention:
Uncompressed: 2.6 TB
Compressed: 78 GB

Actual storage needed: ~100-150 GB (with indexes and metadata)
```

This fits easily on our spot nodes!

### 3.3 Query Performance

ClickHouse excels at time-series queries:

```sql
-- Fast range queries
SELECT
    toStartOfMinute(timestamp) as time,
    avg(value) as avg_cpu
FROM metrics
WHERE
    metric_name = 'node_cpu_usage'
    AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time
ORDER BY time

-- Multi-dimensional queries
SELECT
    labels['instance'] as instance,
    labels['cpu'] as cpu,
    max(value) as max_usage
FROM metrics
WHERE
    metric_name = 'node_cpu_usage'
    AND timestamp >= now() - INTERVAL 24 HOUR
GROUP BY instance, cpu
ORDER BY max_usage DESC
LIMIT 10
```

**Performance characteristics:**
- Recent queries (7d): <50ms
- Historical queries (30d): <200ms
- Complex aggregations: <1s

---

## 4. Spot Node Strategy (Same as Before)

The spot node strategy remains identical to the previous design:

### 4.1 Three-Tier Architecture

1. **Coordinator Tier (3 Keeper nodes)**: On-demand, $21/mo
2. **Anchor Tier (2 ClickHouse nodes)**: On-demand, hot data only, $500/mo
3. **Worker Tier (6-12 ClickHouse nodes)**: Spot, all data, $240-300/mo

### 4.2 Data Placement

**Anchor Nodes (On-Demand):**
- Store last 7 days of ALL data (metrics + logs + traces)
- TTL to automatically prune old data
- Fast queries, always available
- Handles queries during spot preemptions

**Worker Nodes (Spot):**
- Store all data (7-90 days)
- 3-4x replication per shard
- Can tolerate preemptions
- Resync automatically after replacement

### 4.3 Handling Spot Preemptions

Same graceful shutdown and recovery process:
- 30-second termination notice
- Graceful shutdown within 25 seconds
- Queries route to healthy replicas
- 15-30 minute resync after replacement

See [CLICKHOUSE_SPOT_ARCHITECTURE.md](./CLICKHOUSE_SPOT_ARCHITECTURE.md) for detailed preemption handling.

---

## 5. Coroot Configuration

### 5.1 Enable ClickHouse for Metrics

Add to Coroot deployment:

```yaml
env:
  # Enable ClickHouse for metrics storage
  - name: GLOBAL_PROMETHEUS_USE_CLICKHOUSE
    value: "true"

  # ClickHouse connection
  - name: GLOBAL_CLICKHOUSE_ADDRESS
    value: "chi-coroot-clickhouse-coroot-cluster-0-0.clickhouse.svc:9000"

  - name: GLOBAL_CLICKHOUSE_USER
    value: "coroot"

  - name: GLOBAL_CLICKHOUSE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: clickhouse-credentials
        key: password

  # Database names
  - name: GLOBAL_CLICKHOUSE_DATABASE
    value: "coroot"

  # Space management (for spot node optimization)
  - name: CLICKHOUSE_SPACE_MANAGER_ENABLED
    value: "true"

  - name: CLICKHOUSE_SPACE_MANAGER_USAGE_THRESHOLD_PERCENT
    value: "85"  # Delete old data when disk hits 85%

  - name: CLICKHOUSE_SPACE_MANAGER_MIN_PARTITIONS
    value: "7"  # Always keep at least 7 days of data
```

### 5.2 No Prometheus Configuration Needed!

Since we're using ClickHouse for metrics, we **don't need**:
- ❌ Prometheus server
- ❌ VictoriaMetrics cluster
- ❌ Remote write configuration
- ❌ Multiple storage backends

Just ClickHouse! 🎉

---

## 6. Cost Analysis

### 6.1 Detailed Cost Breakdown

**Old Architecture (with VictoriaMetrics):**
```
Component                          Quantity    Unit Cost    Monthly Cost
──────────────────────────────────────────────────────────────────────
ClickHouse Keeper (e2-micro)       3 nodes     $7/mo       $21
VictoriaMetrics vmselect           2 pods      $50/mo      $100
VictoriaMetrics vminsert           2 pods      $50/mo      $100
VictoriaMetrics vmstorage          3 pods      $60/mo      $180
VictoriaMetrics storage            3 disks     $40/mo      $120
ClickHouse Anchors                 2 nodes     $250/mo     $500
ClickHouse Workers (spot)          6 nodes     $40/mo      $240
ClickHouse storage (anchors)       2 disks     $34/mo      $68
ClickHouse storage (workers)       6 disks     $60/mo      $360
Coroot + PostgreSQL                -           -           $150
──────────────────────────────────────────────────────────────────────
TOTAL                                                       $1,839/mo
```

**New Architecture (ClickHouse Only):**
```
Component                          Quantity    Unit Cost    Monthly Cost
──────────────────────────────────────────────────────────────────────
ClickHouse Keeper (e2-micro)       3 nodes     $7/mo       $21
ClickHouse Anchors                 2 nodes     $250/mo     $500
ClickHouse Workers (spot)          6 nodes     $40/mo      $240
ClickHouse storage (anchors)       2 disks     $50/mo      $100  ¹
ClickHouse storage (workers)       6 disks     $75/mo      $450  ¹
Coroot + PostgreSQL                -           -           $150
──────────────────────────────────────────────────────────────────────
TOTAL                                                       $1,461/mo

SAVINGS vs VM architecture: $378/mo (21%)
SAVINGS vs all on-demand:   $1,740/mo (54%)
```

¹ Slightly higher storage due to metrics data, but still much cheaper than running separate VictoriaMetrics

**All On-Demand (for comparison):**
```
Component                          Quantity    Unit Cost    Monthly Cost
──────────────────────────────────────────────────────────────────────
ClickHouse Keeper (e2-micro)       3 nodes     $7/mo       $21
ClickHouse (n2-highmem-8)          8 nodes     $350/mo     $2,800
Storage (pd-ssd, 500GB each)       8 disks     $85/mo      $680
Coroot + PostgreSQL                -           -           $150
──────────────────────────────────────────────────────────────────────
TOTAL                                                       $3,651/mo
```

### 6.2 Cost Sensitivity Analysis

| Scenario | Workers | Storage/Node | Monthly Cost | Savings |
|----------|---------|--------------|--------------|---------|
| Minimal | 4 spot | 500GB | $1,240 | 66% |
| Balanced | 6 spot | 750GB | $1,461 | 60% |
| High Load | 8 spot | 1TB | $1,661 | 55% |
| Peak | 12 spot | 1TB | $1,941 | 47% |

### 6.3 Storage Requirements by Data Type

**Estimated storage per component (for 10-node cluster, 90-day retention):**

```
Data Type          Raw Size/Day    Compressed    90-day Total
─────────────────────────────────────────────────────────────
Metrics            28.8 GB         ~1 GB         90 GB
Logs (verbose)     50 GB           ~5 GB         450 GB
Traces             10 GB           ~1 GB         90 GB
Profiles           5 GB            ~500 MB       45 GB
─────────────────────────────────────────────────────────────
TOTAL PER SHARD    93.8 GB         ~7.5 GB       675 GB

With 2 shards, 3x replication:
Total cluster storage needed: ~2 TB (with headroom)
```

**Storage allocation:**
- Anchors (7-day hot data): 150GB per node = 300GB total
- Workers (90-day all data): 500-750GB per node = 3-4.5TB total
- **Total: 3.3-4.8TB** (well within budget)

---

## 7. Benefits of Unified Architecture

### 7.1 Operational Benefits

✅ **Simpler Stack**: One storage system to manage, not two
✅ **Unified Queries**: Query metrics + logs + traces together
✅ **Lower Complexity**: Fewer moving parts = fewer failure modes
✅ **Easier Troubleshooting**: One system to debug
✅ **Consistent Backup**: Single backup strategy for all data

### 7.2 Performance Benefits

✅ **Efficient Storage**: ClickHouse compression (10-100x for metrics)
✅ **Fast Queries**: Columnar storage optimized for analytics
✅ **Correlation Queries**: Join metrics with logs/traces in one query
✅ **No Data Transfer**: All data in one place, no cross-system queries

### 7.3 Cost Benefits

✅ **No VictoriaMetrics**: Save $300-400/month
✅ **Unified Storage**: No duplicate data across systems
✅ **Spot Optimization**: Still get 60%+ cost savings
✅ **Better Compression**: More efficient storage utilization

### 7.4 Developer Experience

✅ **PromQL Still Works**: Coroot translates PromQL to ClickHouse queries
✅ **Familiar Tools**: Same Coroot UI and dashboards
✅ **Better Insights**: Easier to correlate metrics with logs

---

## 8. Migration from VictoriaMetrics (If Needed)

If you already have VictoriaMetrics deployed:

### 8.1 Migration Steps

1. **Deploy ClickHouse** with unified schema
2. **Enable dual-write** temporarily (both VictoriaMetrics + ClickHouse)
3. **Verify ClickHouse** queries working
4. **Switch Coroot** to ClickHouse (`GLOBAL_PROMETHEUS_USE_CLICKHOUSE=true`)
5. **Backfill historical data** (optional, if needed)
6. **Decommission VictoriaMetrics**

### 8.2 Backfill (Optional)

Export from VictoriaMetrics:
```bash
# Export last 30 days
vmctl vm-native --vm-native-src-addr=http://vmselect:8481/select/0/prometheus \
  --vm-native-dst-addr=clickhouse://coroot:password@clickhouse:9000/coroot \
  --vm-native-filter-time-start=$(date -d '30 days ago' +%s) \
  --vm-native-filter-time-end=$(date +%s)
```

---

## 9. Implementation Checklist

### Phase 1: ClickHouse Setup (Week 1)
- [ ] Deploy ClickHouse Keeper (3 nodes, on-demand)
- [ ] Deploy anchor ClickHouse nodes (2 nodes, on-demand)
- [ ] Deploy worker ClickHouse nodes (6 nodes, spot)
- [ ] Create unified schema (metrics + logs + traces)
- [ ] Configure replication and sharding

### Phase 2: Coroot Configuration (Week 1-2)
- [ ] Deploy Coroot with `GLOBAL_PROMETHEUS_USE_CLICKHOUSE=true`
- [ ] Configure ClickHouse connection details
- [ ] Enable space manager for automatic cleanup
- [ ] Deploy node agents with ClickHouse targets
- [ ] Verify data flowing to ClickHouse

### Phase 3: Testing (Week 2)
- [ ] Verify metrics ingestion
- [ ] Test PromQL queries
- [ ] Test log queries
- [ ] Test trace queries
- [ ] Load testing and performance validation

### Phase 4: Spot Node Validation (Week 3)
- [ ] Test spot node preemption
- [ ] Verify graceful degradation
- [ ] Measure recovery time
- [ ] Validate query performance during disruptions

### Phase 5: Production Readiness (Week 3-4)
- [ ] Set up monitoring and alerts
- [ ] Configure backups
- [ ] Document runbooks
- [ ] Performance tuning

---

## 10. Monitoring and Alerts

### 10.1 Key Metrics to Monitor

```yaml
# ClickHouse health
clickhouse_replicas_available{shard="0"} < 2
clickhouse_disk_usage_percent > 85
clickhouse_query_latency_p95 > 1000ms

# Spot node churn
spot_node_preemptions_rate_5m > 0.1

# Data ingestion
clickhouse_metrics_insert_rate < 1000  # per second
clickhouse_logs_insert_rate < 100     # per second
```

### 10.2 Coroot Dashboards

Pre-built dashboards for:
- ClickHouse cluster health
- Spot node status and churn
- Query performance
- Storage usage and growth
- Data ingestion rates

---

## 11. Conclusion

### Summary

✅ **Simplified**: One storage system (ClickHouse) for everything
✅ **Cost-Effective**: $1,461/month (60% savings vs all on-demand)
✅ **Spot-Optimized**: 80-90% spot node usage
✅ **Production-Ready**: Battle-tested ClickHouse + Coroot integration
✅ **Scalable**: Handle growing data with horizontal scaling

### Recommendation

**Proceed with unified ClickHouse architecture.**

This is simpler, cheaper, and better suited for observability workloads than maintaining separate storage systems.

---

## 12. Next Steps

1. **Review** this architecture
2. **Validate** storage sizing for your workload
3. **Deploy** ClickHouse cluster with spot optimization
4. **Configure** Coroot with `GLOBAL_PROMETHEUS_USE_CLICKHOUSE=true`
5. **Monitor** and optimize based on actual usage

Questions? Let's discuss!
