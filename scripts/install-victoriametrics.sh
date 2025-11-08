#!/bin/bash
set -e

echo "Installing VictoriaMetrics Operator and Cluster..."

# Add VictoriaMetrics Helm repository
echo "Adding VictoriaMetrics Helm repository..."
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update

# Create namespace
echo "Creating victoria-metrics namespace..."
kubectl apply -f ../k8s/victoriametrics/00-namespace.yaml

# Install VictoriaMetrics Operator
echo "Installing VictoriaMetrics Operator..."
helm upgrade --install vm-operator vm/victoria-metrics-operator \
  --namespace victoria-metrics \
  --set operator.enable_converter_ownership=true \
  --wait

# Wait for operator to be ready
echo "Waiting for operator to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=victoria-metrics-operator \
  -n victoria-metrics \
  --timeout=300s

# Install VictoriaMetrics Cluster
echo "Installing VictoriaMetrics Cluster..."
helm upgrade --install victoria-metrics-cluster vm/victoria-metrics-cluster \
  --namespace victoria-metrics \
  --values ../k8s/victoriametrics/victoria-metrics-cluster-values.yaml \
  --wait \
  --timeout=10m

echo ""
echo "VictoriaMetrics installation completed!"
echo ""
echo "Verify installation:"
echo "  kubectl get pods -n victoria-metrics"
echo "  kubectl get vmcluster -n victoria-metrics"
echo ""
echo "VMSelect endpoint (for queries): vmselect-victoria-metrics-cluster.victoria-metrics.svc:8481"
echo "VMInsert endpoint (for writes): vminsert-victoria-metrics-cluster.victoria-metrics.svc:8480"
echo ""
echo "To port-forward vmselect for testing:"
echo "  kubectl port-forward -n victoria-metrics svc/vmselect-victoria-metrics-cluster 8481:8481"
