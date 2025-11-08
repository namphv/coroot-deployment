#!/bin/bash
set -e

echo "Installing ClickHouse with Altinity Operator..."

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

# Deploy ClickHouse Keeper
echo "Deploying ClickHouse Keeper cluster..."
kubectl apply -f ../k8s/clickhouse/clickhouse-keeper.yaml

# Wait for ClickHouse Keeper to be ready
echo "Waiting for ClickHouse Keeper to be ready..."
kubectl wait --for=condition=ready pod \
  -l app=clickhouse-keeper \
  -n clickhouse \
  --timeout=300s

echo "Waiting for all ClickHouse Keeper replicas..."
sleep 30

# Deploy ClickHouse cluster
echo "Deploying ClickHouse cluster..."
kubectl apply -f ../k8s/clickhouse/clickhouse-cluster.yaml

# Wait for ClickHouse to be ready
echo "Waiting for ClickHouse cluster to be ready (this may take several minutes)..."
echo "You can monitor progress with: kubectl get pods -n clickhouse -w"

# Wait for at least one ClickHouse pod
kubectl wait --for=condition=ready pod \
  -l clickhouse.altinity.com/app=chop \
  -n clickhouse \
  --timeout=600s || echo "Note: Some pods may still be initializing"

echo ""
echo "ClickHouse installation completed!"
echo ""
echo "Verify installation:"
echo "  kubectl get chi -n clickhouse"
echo "  kubectl get pods -n clickhouse"
echo ""
echo "ClickHouse service endpoints:"
echo "  TCP: chi-coroot-clickhouse-coroot-cluster-0-0.clickhouse.svc:9000"
echo "  HTTP: chi-coroot-clickhouse-coroot-cluster-0-0.clickhouse.svc:8123"
echo ""
echo "Default credentials:"
echo "  User: coroot"
echo "  Password: coroot123 (PLEASE CHANGE THIS!)"
echo ""
echo "To connect to ClickHouse:"
echo "  kubectl exec -it -n clickhouse chi-coroot-clickhouse-coroot-cluster-0-0-0 -- clickhouse-client"
echo ""
echo "SECURITY NOTE: Change the default password in clickhouse-cluster.yaml"
echo "The password_sha256_hex field should be updated with a secure password hash"
