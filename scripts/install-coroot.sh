#!/bin/bash
set -e

echo "Installing Coroot with external VictoriaMetrics and ClickHouse..."

# Prerequisites check
echo "Checking prerequisites..."

# Check if VictoriaMetrics is running
if ! kubectl get pods -n victoria-metrics -l app.kubernetes.io/name=vmstorage | grep -q Running; then
  echo "ERROR: VictoriaMetrics is not running. Please install it first."
  echo "Run: ./install-victoriametrics.sh"
  exit 1
fi

# Check if ClickHouse is running
if ! kubectl get pods -n clickhouse -l clickhouse.altinity.com/app=chop | grep -q Running; then
  echo "ERROR: ClickHouse is not running. Please install it first."
  echo "Run: ./install-clickhouse.sh"
  exit 1
fi

echo "Prerequisites check passed!"

# Create monitoring namespace
echo "Creating monitoring namespace..."
kubectl apply -f ../k8s/namespaces/monitoring-namespace.yaml

# Add Coroot Helm repository
echo "Adding Coroot Helm repository..."
helm repo add coroot https://coroot.github.io/helm-charts
helm repo update

# Create ClickHouse database for Coroot
echo "Creating Coroot database in ClickHouse..."
kubectl exec -it -n clickhouse chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \
  clickhouse-client --user=coroot --password=coroot123 --query="CREATE DATABASE IF NOT EXISTS coroot" || \
  echo "Note: Database may already exist or ClickHouse pod name may differ"

# Install Coroot
echo "Installing Coroot..."
helm upgrade --install coroot coroot/coroot \
  --namespace monitoring \
  --values ../k8s/coroot/coroot-values.yaml \
  --wait \
  --timeout=10m

echo ""
echo "Coroot installation completed!"
echo ""
echo "Verify installation:"
echo "  kubectl get pods -n monitoring"
echo ""

# Get service details
echo "Getting Coroot service details..."
kubectl get svc -n monitoring coroot

echo ""
echo "Access Coroot:"

# Check if LoadBalancer or ClusterIP
SERVICE_TYPE=$(kubectl get svc -n monitoring coroot -o jsonpath='{.spec.type}')

if [ "$SERVICE_TYPE" == "LoadBalancer" ]; then
  echo "Waiting for LoadBalancer IP..."
  kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' \
    svc/coroot -n monitoring --timeout=300s || true

  EXTERNAL_IP=$(kubectl get svc -n monitoring coroot -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

  if [ -n "$EXTERNAL_IP" ]; then
    echo "  URL: http://${EXTERNAL_IP}:8080"
  else
    echo "  LoadBalancer IP not yet assigned. Check with: kubectl get svc -n monitoring coroot"
  fi
else
  echo "  Port-forward: kubectl port-forward -n monitoring svc/coroot 8080:8080"
  echo "  Then access: http://localhost:8080"
fi

echo ""
echo "Default credentials:"
echo "  Username: admin"
echo "  Password: admin (PLEASE CHANGE THIS!)"
echo ""
echo "Architecture verification:"
echo "  - Metrics storage: VictoriaMetrics (victoria-metrics namespace)"
echo "  - Logs/Traces storage: ClickHouse (clickhouse namespace)"
echo "  - Coroot agents: Running on all nodes (DaemonSet)"
echo ""
echo "To view components:"
echo "  kubectl get pods -n monitoring"
echo "  kubectl get pods -n victoria-metrics"
echo "  kubectl get pods -n clickhouse"
echo ""
echo "SECURITY NOTES:"
echo "1. Change the default admin password in Coroot UI"
echo "2. Update ClickHouse password in coroot-values.yaml"
echo "3. Update PostgreSQL password in coroot-values.yaml"
echo "4. Consider enabling Ingress with TLS for production"
