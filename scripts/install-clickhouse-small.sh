#!/bin/bash
set -e

echo "Installing ClickHouse Small Efficient Deployment..."
echo "Configuration: 1 shard, 2 replicas (anchor + worker)"
echo ""

# Create namespace
echo "Creating clickhouse namespace..."
kubectl apply -f ../k8s/clickhouse/00-namespace.yaml

# Install ClickHouse Operator
echo "Installing ClickHouse Operator..."
kubectl apply -f https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator/clickhouse-operator-install-bundle.yaml

# Wait for operator to be ready
echo "Waiting for ClickHouse Operator to be ready..."
kubectl wait --for=condition=ready pod \
  -l app=clickhouse-operator \
  -n kube-system \
  --timeout=300s || true

# Deploy ClickHouse Keeper (minimal resources)
echo "Deploying ClickHouse Keeper cluster (3 replicas, ~450MB total)..."
kubectl apply -f ../k8s/clickhouse/small-efficient/clickhouse-keeper-minimal.yaml

# Wait for ClickHouse Keeper to be ready
echo "Waiting for ClickHouse Keeper to be ready..."
kubectl wait --for=condition=ready pod \
  -l app=clickhouse-keeper \
  -n clickhouse \
  --timeout=300s

echo "Waiting for all ClickHouse Keeper replicas..."
sleep 30

# Deploy ClickHouse cluster (small configuration)
echo "Deploying ClickHouse cluster (1 shard, 2 replicas)..."
echo "  - Anchor replica: Regular node, ~2.5GB RAM, 50GB storage"
echo "  - Worker replica: Spot node, ~16-32GB RAM, 500GB storage"
kubectl apply -f ../k8s/clickhouse/small-efficient/clickhouse-cluster-small.yaml

# Wait for ClickHouse to be ready
echo "Waiting for ClickHouse cluster to be ready (this may take several minutes)..."
echo "You can monitor progress with: kubectl get pods -n clickhouse -w"

# Wait for at least one ClickHouse pod
kubectl wait --for=condition=ready pod \
  -l clickhouse.altinity.com/app=chop \
  -n clickhouse \
  --timeout=600s || echo "Note: Some pods may still be initializing"

echo ""
echo "ClickHouse Small Efficient Deployment completed!"
echo ""
echo "Verify installation:"
echo "  kubectl get chi -n clickhouse"
echo "  kubectl get pods -n clickhouse -o wide"
echo ""

# Show pod placement
echo "Pod placement:"
kubectl get pods -n clickhouse -o wide --show-labels | grep -E "NAME|clickhouse"

echo ""
echo "Resource usage:"
kubectl top pods -n clickhouse || echo "(Metrics server may not be ready yet)"

echo ""
echo "ClickHouse service endpoints:"
echo "  TCP: chi-coroot-clickhouse-small-coroot-cluster-0-0.clickhouse.svc:9000"
echo "  HTTP: chi-coroot-clickhouse-small-coroot-cluster-0-0.clickhouse.svc:8123"
echo ""
echo "Default credentials:"
echo "  User: coroot"
echo "  Password: coroot123 (PLEASE CHANGE THIS!)"
echo ""
echo "To connect to ClickHouse:"
echo "  # Anchor replica (regular node)"
echo "  kubectl exec -it -n clickhouse chi-coroot-clickhouse-small-coroot-cluster-0-0-0 -- clickhouse-client"
echo ""
echo "  # Worker replica (spot node)"
echo "  kubectl exec -it -n clickhouse chi-coroot-clickhouse-small-coroot-cluster-0-1-0 -- clickhouse-client"
echo ""
echo "Architecture Summary:"
echo "  - Regular Node 1: Keeper-0 + Anchor replica (~2.5GB RAM)"
echo "  - Regular Node 2: Keeper-1 + Coroot (~3GB RAM)"
echo "  - Spot Node:      Keeper-2 + Worker replica (~16GB+ RAM)"
echo ""
echo "Data Strategy:"
echo "  - Anchor (regular): Hot data (7 days), always available"
echo "  - Worker (spot):    All data (30-90 days), main workload"
echo ""
echo "SECURITY NOTE: Change the default password in clickhouse-cluster-small.yaml"
echo "The password_sha256_hex field should be updated with a secure password hash"
