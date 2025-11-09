#!/bin/bash
set -e

echo "=========================================="
echo "  Small Coroot Deployment Installer"
echo "=========================================="
echo ""
echo "This will deploy Coroot with ClickHouse"
echo "optimized for: 2 regular + 1 spot node"
echo ""
echo "Namespace: coroot"
echo "Components:"
echo "  - ClickHouse Keeper (3 replicas, ~450MB)"
echo "  - ClickHouse Cluster (1 shard, 2 replicas)"
echo "    * Anchor (regular node): 1GB RAM, 30GB (fallback)"
echo "    * Worker (spot node): 6-15GB RAM, 500GB (main)"
echo "  - Nginx Proxy (weighted routing: 90% worker, 10% anchor)"
echo "  - Coroot Server (unified ClickHouse storage)"
echo "  - Coroot Node Agents (DaemonSet)"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "Step 1/6: Creating namespace..."
kubectl apply -f "$SCRIPT_DIR/00-namespace.yaml"

echo ""
echo "Step 2/6: Installing ClickHouse Operator..."
kubectl apply -f https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator/clickhouse-operator-install-bundle.yaml

echo "Waiting for ClickHouse Operator..."
kubectl wait --for=condition=ready pod \
  -l app=clickhouse-operator \
  -n kube-system \
  --timeout=300s || echo "Note: Operator may still be initializing"

echo ""
echo "Step 3/6: Deploying ClickHouse Keeper (3 replicas)..."
kubectl apply -f "$SCRIPT_DIR/01-clickhouse-keeper.yaml"

echo "Waiting for ClickHouse Keeper..."
kubectl wait --for=condition=ready pod \
  -l app=clickhouse-keeper \
  -n coroot \
  --timeout=300s || echo "Note: Some Keeper pods may still be starting"

sleep 15

echo ""
echo "Step 4/7: Deploying ClickHouse Cluster (1 shard, 2 replicas)..."
kubectl apply -f "$SCRIPT_DIR/02-clickhouse-cluster.yaml"
kubectl apply -f "$SCRIPT_DIR/02a-clickhouse-service.yaml"

echo "Waiting for ClickHouse cluster (this may take 3-5 minutes)..."
echo "You can monitor with: kubectl get pods -n coroot -w"
kubectl wait --for=condition=ready pod \
  -l clickhouse.altinity.com/app=chop \
  -n coroot \
  --timeout=600s || echo "Note: Some ClickHouse pods may still be initializing"

echo ""
echo "Step 5/7: Deploying Nginx Proxy (weighted routing: 90% worker, 10% anchor)..."
kubectl apply -f "$SCRIPT_DIR/02b-clickhouse-nginx-proxy.yaml"

echo "Waiting for Nginx proxy..."
kubectl wait --for=condition=ready pod \
  -l app=clickhouse-nginx-proxy \
  -n coroot \
  --timeout=120s || echo "Note: Nginx proxy may still be starting"

echo ""
echo "Step 6/7: Adding Coroot Helm repository..."
helm repo add coroot https://coroot.github.io/helm-charts
helm repo update

echo ""
echo "Step 7/7: Installing Coroot with ClickHouse metrics..."
helm upgrade --install coroot coroot/coroot \
  --namespace coroot \
  --values "$SCRIPT_DIR/03-coroot-values.yaml" \
  --wait \
  --timeout=10m

echo ""
echo "=========================================="
echo "  Deployment Complete!"
echo "=========================================="
echo ""

# Show deployment status
echo "Deployment Status:"
echo ""
kubectl get pods -n coroot

echo ""
echo "Resource Usage:"
kubectl top pods -n coroot 2>/dev/null || echo "(Metrics server may not be ready yet)"

echo ""
echo "=========================================="
echo "  Access Coroot"
echo "=========================================="
echo ""

SERVICE_TYPE=$(kubectl get svc -n coroot coroot -o jsonpath='{.spec.type}' 2>/dev/null || echo "ClusterIP")

if [ "$SERVICE_TYPE" == "LoadBalancer" ]; then
    echo "Coroot service type: LoadBalancer"
    echo "Waiting for external IP..."
    kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' \
      svc/coroot -n coroot --timeout=300s 2>/dev/null || true

    EXTERNAL_IP=$(kubectl get svc -n coroot coroot -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -n "$EXTERNAL_IP" ]; then
        echo "  URL: http://${EXTERNAL_IP}:8080"
    else
        echo "  LoadBalancer IP not yet assigned."
        echo "  Check with: kubectl get svc -n coroot coroot"
    fi
else
    echo "Coroot service type: ClusterIP"
    echo "  Port-forward: kubectl port-forward -n coroot svc/coroot 8080:8080"
    echo "  Then access: http://localhost:8080"
fi

echo ""
echo "Default Credentials:"
echo "  Username: admin"
echo "  Password: admin (CHANGE THIS!)"
echo ""

echo "=========================================="
echo "  Architecture Summary"
echo "=========================================="
echo ""
echo "Regular Node 1:"
echo "  - ClickHouse Keeper-0 (~128MB)"
echo "  - ClickHouse Anchor (~1GB)"
echo "  Total: ~1.3GB"
echo ""
echo "Regular Node 2:"
echo "  - ClickHouse Keeper-1 (~128MB)"
echo "  - Nginx Proxy (2 replicas, ~256MB total)"
echo "  - Coroot Server (~2GB)"
echo "  - PostgreSQL (~512MB)"
echo "  Total: ~2.9GB"
echo ""
echo "Spot Node (shared with Chrome Headless):"
echo "  - ClickHouse Keeper-2 (~128MB)"
echo "  - ClickHouse Worker (6-15GB, bursts to use spare CPU)"
echo "  - Chrome Headless (3-12GB, has priority)"
echo "  Total: ~9-27GB depending on load"
echo ""
echo "Traffic Distribution:"
echo "  - Nginx routes 90% traffic to worker (strong spot node)"
echo "  - Nginx routes 10% traffic to anchor (backup only)"
echo "  - When worker down: automatic failover to anchor (100%)"
echo "  - Maximizes spot node usage while maintaining HA"
echo ""

echo "=========================================="
echo "  Important Next Steps"
echo "=========================================="
echo ""
echo "1. Change default passwords:"
echo "   - Coroot admin password (via UI)"
echo "   - ClickHouse password in 02-clickhouse-cluster.yaml"
echo "   - PostgreSQL password in 03-coroot-values.yaml"
echo ""
echo "2. Verify traffic routing (spot node should handle 80-90%):"
echo "   kubectl exec -n coroot chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \\"
echo "     clickhouse-client --user=coroot --password=coroot123 --query=\"\\"
echo "       SELECT hostName(), count() FROM system.query_log \\"
echo "       WHERE event_time > now() - 300 GROUP BY hostName()\""
echo ""
echo "3. Monitor resource usage:"
echo "   kubectl top pods -n coroot"
echo ""
echo "4. Check ClickHouse cluster:"
echo "   kubectl get chi -n coroot"
echo ""
echo "Deployment documentation:"
echo "  - See README.md in this directory"
echo "  - Main docs: ../../SMALL_EFFICIENT_CLICKHOUSE.md"
echo "  - Traffic routing: ../../TRAFFIC_ROUTING_OPTIMIZATION.md"
echo ""
