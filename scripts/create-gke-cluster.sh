#!/bin/bash
set -e

# Configuration
PROJECT_ID="${PROJECT_ID:-your-gcp-project-id}"
REGION="${REGION:-us-central1}"
CLUSTER_NAME="${CLUSTER_NAME:-coroot-monitoring-cluster}"
NETWORK_NAME="${NETWORK_NAME:-coroot-network}"
SUBNET_NAME="${SUBNET_NAME:-coroot-subnet}"

echo "Creating GKE cluster for Coroot monitoring..."
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Cluster: $CLUSTER_NAME"

# Set default project
gcloud config set project "$PROJECT_ID"

# Create VPC Network
echo "Creating VPC network..."
gcloud compute networks create "$NETWORK_NAME" \
  --subnet-mode=custom \
  --bgp-routing-mode=regional \
  --project="$PROJECT_ID" || echo "Network already exists"

# Create Subnet
echo "Creating subnet..."
gcloud compute networks subnets create "$SUBNET_NAME" \
  --network="$NETWORK_NAME" \
  --region="$REGION" \
  --range=10.0.0.0/20 \
  --secondary-range pods=10.4.0.0/14 \
  --secondary-range services=10.8.0.0/20 \
  --enable-private-ip-google-access \
  --project="$PROJECT_ID" || echo "Subnet already exists"

# Create Cloud Router
echo "Creating Cloud Router..."
gcloud compute routers create "${CLUSTER_NAME}-router" \
  --network="$NETWORK_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" || echo "Router already exists"

# Create Cloud NAT
echo "Creating Cloud NAT..."
gcloud compute routers nats create "${CLUSTER_NAME}-nat" \
  --router="${CLUSTER_NAME}-router" \
  --region="$REGION" \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges \
  --enable-logging \
  --log-filter=ERRORS_ONLY \
  --project="$PROJECT_ID" || echo "NAT already exists"

# Create Firewall Rule for internal communication
echo "Creating firewall rules..."
gcloud compute firewall-rules create "${CLUSTER_NAME}-allow-internal" \
  --network="$NETWORK_NAME" \
  --allow=tcp,udp,icmp \
  --source-ranges=10.0.0.0/20,10.4.0.0/14,10.8.0.0/20 \
  --project="$PROJECT_ID" || echo "Firewall rule already exists"

# Create GKE Cluster
echo "Creating GKE cluster..."
gcloud container clusters create "$CLUSTER_NAME" \
  --region="$REGION" \
  --node-locations="${REGION}-a,${REGION}-b,${REGION}-c" \
  --network="$NETWORK_NAME" \
  --subnetwork="$SUBNET_NAME" \
  --cluster-secondary-range-name=pods \
  --services-secondary-range-name=services \
  --enable-ip-alias \
  --enable-network-policy \
  --enable-autoscaling \
  --enable-autorepair \
  --enable-autoupgrade \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --addons=HorizontalPodAutoscaling,HttpLoadBalancing \
  --logging=SYSTEM,WORKLOAD \
  --monitoring=SYSTEM \
  --release-channel=regular \
  --maintenance-window-start=2024-01-01T03:00:00Z \
  --maintenance-window-duration=4h \
  --maintenance-window-recurrence="FREQ=WEEKLY;BYDAY=SU" \
  --num-nodes=1 \
  --machine-type=e2-medium \
  --disk-type=pd-standard \
  --disk-size=50 \
  --no-enable-basic-auth \
  --no-issue-client-certificate \
  --enable-shielded-nodes \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  --labels=environment=prod,managed_by=gcloud,component=monitoring \
  --project="$PROJECT_ID"

echo "Deleting default node pool..."
gcloud container node-pools delete default-pool \
  --cluster="$CLUSTER_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --quiet

# Create Monitoring Node Pool
echo "Creating monitoring node pool..."
gcloud container node-pools create monitoring-pool \
  --cluster="$CLUSTER_NAME" \
  --region="$REGION" \
  --machine-type=n2-standard-8 \
  --disk-type=pd-ssd \
  --disk-size=200 \
  --num-nodes=3 \
  --node-labels=node-type=monitoring,workload=monitoring \
  --node-taints=monitoring=critical:NoSchedule \
  --enable-autorepair \
  --enable-autoupgrade \
  --max-surge-upgrade=1 \
  --max-unavailable-upgrade=0 \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  --project="$PROJECT_ID"

# Create Storage Node Pool
echo "Creating storage node pool..."
gcloud container node-pools create storage-pool \
  --cluster="$CLUSTER_NAME" \
  --region="$REGION" \
  --machine-type=n2-highmem-8 \
  --disk-type=pd-ssd \
  --disk-size=200 \
  --num-nodes=3 \
  --node-labels=node-type=storage,workload=stateful \
  --node-taints=storage=critical:NoSchedule \
  --enable-autorepair \
  --enable-autoupgrade \
  --max-surge-upgrade=1 \
  --max-unavailable-upgrade=0 \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  --project="$PROJECT_ID"

# Create Spot Node Pool
echo "Creating spot node pool..."
gcloud container node-pools create spot-pool \
  --cluster="$CLUSTER_NAME" \
  --region="$REGION" \
  --machine-type=n2-standard-16 \
  --disk-type=pd-standard \
  --disk-size=100 \
  --spot \
  --enable-autoscaling \
  --min-nodes=2 \
  --max-nodes=20 \
  --node-labels=node-type=workload,spot=true \
  --enable-autorepair \
  --enable-autoupgrade \
  --max-surge-upgrade=2 \
  --max-unavailable-upgrade=1 \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  --project="$PROJECT_ID"

# Get cluster credentials
echo "Getting cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID"

echo ""
echo "GKE cluster created successfully!"
echo "Cluster name: $CLUSTER_NAME"
echo "Region: $REGION"
echo ""
echo "Verify your setup:"
echo "  kubectl get nodes"
echo "  kubectl get nodes -L node-type,workload,spot"
