# ClickHouse Tiered Storage Setup Guide

This guide shows how to enable GCS-backed tiered storage for ClickHouse to solve the storage mismatch problem and reduce costs.

## Problem

Current setup:
- **Anchor**: 30Gi storage (will fill up quickly)
- **Worker**: 500Gi storage
- **Issue**: Replicas should have same storage capacity, but anchor only has 30Gi

## Solution: Tiered Storage

**With tiered storage:**
- **Both anchor and worker**: 100Gi local disk (same size ✅)
- **GCS cold tier**: Unlimited cheap storage (~$0.02/GB)
- **Data movement**: Automatic after 7 days OR when disk 80% full
- **Query**: Transparent (ClickHouse fetches from GCS when needed)

## Cost Comparison

**Current (no tiering):**
```
Anchor: 30Gi pd-balanced = $3/month
Worker: 500Gi pd-balanced = $50/month
Total: $53/month

Problem: Anchor fills up → replication fails
```

**With tiering (recommended):**
```
Anchor: 100Gi pd-balanced = $10/month (hot data)
Worker: 100Gi pd-balanced = $10/month (hot data)
GCS: 400Gi cold = $8/month (old data)
Total: $28/month

Savings: $25/month (47% reduction)
Benefits: Both replicas same size, unlimited retention
```

## Prerequisites

### 1. Create GCS Bucket

```bash
# Set variables
export PROJECT_ID="your-project-id"
export BUCKET_NAME="coroot-clickhouse-cold"
export REGION="us-central1"

# Create bucket
gsutil mb -p $PROJECT_ID -l $REGION gs://$BUCKET_NAME

# Set lifecycle (optional - auto-delete after 1 year)
cat > lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {"age": 365}
      }
    ]
  }
}
EOF

gsutil lifecycle set lifecycle.json gs://$BUCKET_NAME
```

### 2. Choose Authentication Method

#### Option A: HMAC Keys (Simpler)

```bash
# Create service account
gcloud iam service-accounts create clickhouse-gcs \\
  --display-name="ClickHouse GCS Access"

# Grant storage access
gsutil iam ch serviceAccount:clickhouse-gcs@${PROJECT_ID}.iam.gserviceaccount.com:objectAdmin \\
  gs://$BUCKET_NAME

# Create HMAC keys
gcloud storage hmac create clickhouse-gcs@${PROJECT_ID}.iam.gserviceaccount.com

# Output:
# Access ID: GOOG1E...
# Secret: wJalrXUtnFEMI/K7MDENG...
```

**Save these credentials - you'll need them!**

#### Option B: Workload Identity (More secure, GKE-specific)

```bash
# Create service account
gcloud iam service-accounts create clickhouse-gcs \\
  --display-name="ClickHouse GCS Access"

# Grant storage access
gsutil iam ch serviceAccount:clickhouse-gcs@${PROJECT_ID}.iam.gserviceaccount.com:objectAdmin \\
  gs://$BUCKET_NAME

# Bind to Kubernetes service account
gcloud iam service-accounts add-iam-policy-binding \\
  clickhouse-gcs@${PROJECT_ID}.iam.gserviceaccount.com \\
  --role roles/iam.workloadIdentityUser \\
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[coroot/clickhouse-gcs]"
```

## Enable Tiered Storage

### 1. Update Storage Sizes (Recommended)

Since both replicas will use tiering, increase anchor storage to match:

```yaml
# In 02-clickhouse-cluster.yaml

# Change anchor storage from 30Gi to 100Gi
- name: anchor-storage
  spec:
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 100Gi  # Was 30Gi
    storageClassName: pd-balanced

# Change worker storage from 500Gi to 100Gi
- name: worker-storage
  spec:
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 100Gi  # Was 500Gi
    storageClassName: pd-balanced
```

### 2. Enable Tiered Storage Config

In `02-clickhouse-cluster.yaml`, find the commented section and uncomment it:

**Before:**
```yaml
      # config.d/storage.xml: |
      #   <clickhouse>
      #     <storage_configuration>
```

**After (uncomment and configure):**
```yaml
      config.d/storage.xml: |
        <clickhouse>
          <storage_configuration>
            <disks>
              <default>
                <type>local</type>
                <path>/var/lib/clickhouse/</path>
              </default>

              <gcs>
                <type>s3</type>
                <endpoint>https://storage.googleapis.com/YOUR_BUCKET_NAME/clickhouse/</endpoint>

                <!-- OPTION A: Using HMAC keys -->
                <access_key_id>GOOG1E_YOUR_ACCESS_KEY</access_key_id>
                <secret_access_key>YOUR_SECRET_KEY</secret_access_key>
                <use_environment_credentials>false</use_environment_credentials>

                <!-- OPTION B: Using Workload Identity (comment out keys above) -->
                <!-- <use_environment_credentials>true</use_environment_credentials> -->

                <cache_enabled>true</cache_enabled>
                <cache_path>/var/lib/clickhouse/disks/gcs_cache/</cache_path>
                <cache_max_size>10Gi</cache_max_size>
              </gcs>
            </disks>

            <policies>
              <tiered>
                <volumes>
                  <hot>
                    <disk>default</disk>
                  </hot>
                  <cold>
                    <disk>gcs</disk>
                  </cold>
                </volumes>
                <move_factor>0.2</move_factor>
              </tiered>

              <default>
                <volumes>
                  <main>
                    <disk>default</disk>
                  </main>
                </volumes>
              </default>
            </policies>
          </storage_configuration>

          <merge_tree>
            <storage_policy>tiered</storage_policy>
          </merge_tree>
        </clickhouse>
```

### 3. Add Workload Identity ServiceAccount (if using Option B)

In `02-clickhouse-cluster.yaml`, add serviceAccount to both anchor and worker pod templates:

```yaml
spec:
  serviceAccountName: clickhouse-gcs  # Add this line
  affinity:
    nodeAffinity:
      # ... rest of config
```

Then create the ServiceAccount:

```yaml
# Add to 02-clickhouse-cluster.yaml or create separate file
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: clickhouse-gcs
  namespace: coroot
  annotations:
    iam.gke.io/gcp-service-account: clickhouse-gcs@YOUR_PROJECT.iam.gserviceaccount.com
```

### 4. Deploy

```bash
# Apply updated configuration
kubectl apply -f 02-clickhouse-cluster.yaml

# ClickHouse will restart and pick up new storage config
# Existing data stays on local disk
# New data after 7 days moves to GCS automatically
```

## Verification

### Check Storage Policy

```bash
kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \\
  clickhouse-client --user=coroot --password=coroot123 --query="
    SELECT
      policy_name,
      volume_name,
      disks
    FROM system.storage_policies
    WHERE policy_name = 'tiered'"
```

**Expected output:**
```
tiered    hot     ['default']
tiered    cold    ['gcs']
```

### Check Data Distribution

```bash
kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \\
  clickhouse-client --user=coroot --password=coroot123 --query="
    SELECT
      database,
      table,
      disk_name,
      formatReadableSize(sum(bytes_on_disk)) as size,
      count() as parts
    FROM system.parts
    WHERE active
    GROUP BY database, table, disk_name
    ORDER BY sum(bytes_on_disk) DESC"
```

**Expected output (after data moves):**
```
coroot    metrics    default    15.2 GiB    120    <- Recent data (hot)
coroot    metrics    gcs        380.5 GiB   2340   <- Old data (cold)
```

### Monitor GCS Usage

```bash
# Check GCS bucket size
gsutil du -sh gs://$BUCKET_NAME

# List objects
gsutil ls gs://$BUCKET_NAME/clickhouse/
```

## Data Movement

**Automatic movement triggers:**
1. **Time-based**: Data older than 7 days moves to GCS
2. **Space-based**: When local disk reaches 80% full (move_factor=0.2)

**Manual movement (if needed):**
```sql
-- Move specific partition to cold storage
ALTER TABLE metrics MOVE PARTITION '2024-01' TO VOLUME 'cold';

-- Move all old data to cold
OPTIMIZE TABLE metrics FINAL;
```

## Troubleshooting

### Issue: Data not moving to GCS

**Check:**
```bash
# Check ClickHouse logs
kubectl logs -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 | grep -i "storage\|gcs\|s3"

# Check merge operations
kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \\
  clickhouse-client --user=coroot --password=coroot123 --query="
    SELECT * FROM system.merges"
```

### Issue: GCS authentication failed

**Check credentials:**
```bash
# For HMAC keys - verify keys are correct
kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \\
  env | grep -i gcs

# For Workload Identity - check binding
gcloud iam service-accounts get-iam-policy \\
  clickhouse-gcs@${PROJECT_ID}.iam.gserviceaccount.com
```

### Issue: Slow queries on cold data

**This is expected!** Cold data is fetched from GCS:
- Local disk: 100-500ms
- GCS cold tier: 2-10s (first fetch), then cached

**Optimize:**
- Increase cache size: `<cache_max_size>20Gi</cache_max_size>`
- Query recent data only (last 7 days stays on local disk)

## Rollback

If you need to disable tiered storage:

```yaml
# Comment out storage config
# config.d/storage.xml: |

# Change storage policy back to default
# <merge_tree>
#   <storage_policy>default</storage_policy>
# </merge_tree>
```

**Note:** Data in GCS remains accessible, but new data won't be tiered.

## Summary

**Benefits of tiered storage:**
- ✅ Solves storage mismatch (both replicas same size)
- ✅ Reduces costs by 47% ($53 → $28/month)
- ✅ Unlimited retention capacity (GCS is cheap)
- ✅ Automatic data movement (no manual intervention)
- ✅ Transparent to applications (Coroot doesn't know)

**Trade-offs:**
- Queries on old data (>7 days) are slower (2-10s vs 100ms)
- Requires GCS setup and credentials management
- Adds complexity to architecture

For observability workloads where recent data (last 7 days) is queried 90% of the time, this is an excellent trade-off!
