# Coroot Monitoring System - Deployment Guide

This guide provides step-by-step instructions for deploying Coroot monitoring system on Google Kubernetes Engine (GKE) with external VictoriaMetrics and ClickHouse.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Architecture Overview](#architecture-overview)
3. [Deployment Steps](#deployment-steps)
4. [Verification](#verification)
5. [Configuration](#configuration)
6. [Troubleshooting](#troubleshooting)
7. [Maintenance](#maintenance)
8. [Security Hardening](#security-hardening)

## Prerequisites

### Required Tools

- **gcloud CLI**: Latest version
  ```bash
  # Install gcloud
  curl https://sdk.cloud.google.com | bash
  exec -l $SHELL
  gcloud init
  ```

- **kubectl**: Version 1.25+
  ```bash
  gcloud components install kubectl
  ```

- **Helm**: Version 3.10+
  ```bash
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ```

- **Terraform** (optional): Version 1.5+
  ```bash
  # For macOS
  brew install terraform

  # For Linux
  wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
  unzip terraform_1.6.0_linux_amd64.zip
  sudo mv terraform /usr/local/bin/
  ```

### GCP Requirements

- GCP Project with billing enabled
- Sufficient quota for:
  - At least 12-20 vCPUs
  - 100GB+ of persistent disk
  - Regional IP addresses
- IAM permissions:
  - Kubernetes Engine Admin
  - Compute Admin
  - Service Account Admin

## Architecture Overview

The deployment consists of:

- **GKE Cluster** with 3 node pools:
  - Monitoring nodes (regular): Critical monitoring infrastructure
  - Storage nodes (regular): Stateful workloads (ClickHouse, VictoriaMetrics)
  - Spot nodes (preemptible): Application workloads

- **VictoriaMetrics Cluster**: Time-series metrics storage
  - vmselect: Query interface
  - vminsert: Data ingestion
  - vmstorage: Persistent storage

- **ClickHouse Cluster**: Logs, traces, and profiling data
  - 2 shards with 2 replicas each
  - ClickHouse Keeper for coordination

- **Coroot**: Observability platform
  - Coroot server (2 replicas)
  - Node agents (DaemonSet on all nodes)
  - Cluster agent (metadata collection)

See [SYSTEM_DESIGN.md](./SYSTEM_DESIGN.md) for detailed architecture.

## Deployment Steps

### Step 1: Set Environment Variables

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-central1"
export CLUSTER_NAME="coroot-monitoring-cluster"

# Set default project
gcloud config set project $PROJECT_ID
```

### Step 2: Create GKE Cluster

#### Option A: Using Terraform (Recommended)

```bash
cd terraform

# Copy and edit variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Initialize Terraform
terraform init

# Review plan
terraform plan

# Apply configuration
terraform apply

# Get cluster credentials
$(terraform output -raw get_credentials_command)
```

#### Option B: Using gcloud Script

```bash
cd scripts

# Edit the script to set your variables
vim create-gke-cluster.sh

# Run the script
./create-gke-cluster.sh
```

### Step 3: Verify Cluster

```bash
# Check cluster status
gcloud container clusters describe $CLUSTER_NAME --region $REGION

# Check nodes
kubectl get nodes -L node-type,workload,spot

# Expected output:
# - 3 monitoring nodes (node-type=monitoring)
# - 3 storage nodes (node-type=storage)
# - 2+ spot nodes (spot=true)
```

### Step 4: Install VictoriaMetrics

```bash
cd scripts

# Install VictoriaMetrics Operator and Cluster
./install-victoriametrics.sh

# Wait for all pods to be ready (may take 3-5 minutes)
kubectl get pods -n victoria-metrics -w

# Verify installation
kubectl get vmcluster -n victoria-metrics
```

Expected output:
```
NAME                        READY   STATUS    RESTARTS   AGE
vminsert-...-0              1/1     Running   0          2m
vminsert-...-1              1/1     Running   0          2m
vmselect-...-0              1/1     Running   0          2m
vmselect-...-1              1/1     Running   0          2m
vmstorage-...-0             1/1     Running   0          2m
vmstorage-...-1             1/1     Running   0          2m
vmstorage-...-2             1/1     Running   0          2m
```

### Step 5: Install ClickHouse

```bash
# Install ClickHouse Operator, ClickHouse Keeper, and ClickHouse Cluster
./install-clickhouse.sh

# Wait for all pods to be ready (may take 5-10 minutes)
kubectl get pods -n clickhouse -w

# Verify installation
kubectl get chi -n clickhouse
```

Expected output:
```
NAME                        READY   STATUS    RESTARTS   AGE
clickhouse-keeper-0         1/1     Running   0          5m
clickhouse-keeper-1         1/1     Running   0          5m
clickhouse-keeper-2         1/1     Running   0          5m
chi-coroot-...-0-0-0        1/1     Running   0          3m
chi-coroot-...-0-1-0        1/1     Running   0          3m
chi-coroot-...-1-0-0        1/1     Running   0          3m
chi-coroot-...-1-1-0        1/1     Running   0          3m
```

### Step 6: Install Coroot

```bash
# Install Coroot with external VictoriaMetrics and ClickHouse
./install-coroot.sh

# Wait for all pods to be ready (may take 3-5 minutes)
kubectl get pods -n monitoring -w

# Check all components
kubectl get pods -n monitoring
```

Expected output:
```
NAME                           READY   STATUS    RESTARTS   AGE
coroot-0                       1/1     Running   0          2m
coroot-1                       1/1     Running   0          2m
coroot-postgresql-0            1/1     Running   0          2m
coroot-node-agent-xxxxx        1/1     Running   0          2m  (one per node)
coroot-cluster-agent-xxxxx     1/1     Running   0          2m
```

### Step 7: Access Coroot UI

#### If using LoadBalancer:

```bash
# Get LoadBalancer IP
kubectl get svc -n monitoring coroot

# Access Coroot at http://<EXTERNAL-IP>:8080
```

#### If using port-forward:

```bash
kubectl port-forward -n monitoring svc/coroot 8080:8080

# Access Coroot at http://localhost:8080
```

Default credentials:
- Username: `admin`
- Password: `admin` (change immediately!)

## Verification

### 1. Check All Components

```bash
# VictoriaMetrics
kubectl get pods -n victoria-metrics
kubectl get svc -n victoria-metrics

# ClickHouse
kubectl get pods -n clickhouse
kubectl get chi -n clickhouse

# Coroot
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

### 2. Verify Data Flow

```bash
# Check VictoriaMetrics metrics ingestion
kubectl port-forward -n victoria-metrics svc/vmselect-victoria-metrics-cluster 8481:8481

# Query metrics (in another terminal)
curl 'http://localhost:8481/select/0/prometheus/api/v1/query?query=up'

# Check ClickHouse connectivity
kubectl exec -it -n clickhouse chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \
  clickhouse-client --user=coroot --password=coroot123 --query="SHOW DATABASES"
```

### 3. Verify Node Agents

```bash
# Check node agents are running on all nodes
kubectl get pods -n monitoring -l app.kubernetes.io/name=coroot-node-agent -o wide

# Check agent logs
kubectl logs -n monitoring -l app.kubernetes.io/name=coroot-node-agent --tail=50
```

### 4. Check Resource Usage

```bash
# Overall cluster resources
kubectl top nodes

# VictoriaMetrics resource usage
kubectl top pods -n victoria-metrics

# ClickHouse resource usage
kubectl top pods -n clickhouse

# Coroot resource usage
kubectl top pods -n monitoring
```

## Configuration

### Update ClickHouse Password

1. Generate a password hash:
```bash
echo -n "your-secure-password" | sha256sum
```

2. Edit `k8s/clickhouse/clickhouse-cluster.yaml`:
```yaml
coroot/password_sha256_hex: "YOUR_HASH_HERE"
```

3. Apply changes:
```bash
kubectl apply -f k8s/clickhouse/clickhouse-cluster.yaml
```

4. Update Coroot values:
```yaml
# k8s/coroot/coroot-values.yaml
externalClickhouse:
  password: your-secure-password
```

5. Upgrade Coroot:
```bash
helm upgrade coroot coroot/coroot \
  -n monitoring \
  -f k8s/coroot/coroot-values.yaml
```

### Configure Ingress (Production)

1. Install nginx-ingress controller:
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace
```

2. Install cert-manager:
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

3. Create ClusterIssuer:
```yaml
# letsencrypt-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
```

4. Update Coroot values to enable Ingress:
```yaml
# k8s/coroot/coroot-values.yaml
corootCE:
  service:
    type: ClusterIP

  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: coroot.yourdomain.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: coroot-tls
        hosts:
          - coroot.yourdomain.com
```

5. Upgrade Coroot:
```bash
helm upgrade coroot coroot/coroot \
  -n monitoring \
  -f k8s/coroot/coroot-values.yaml
```

### Adjust Resource Limits

Edit the values files based on your workload:

- `k8s/victoriametrics/victoria-metrics-cluster-values.yaml`
- `k8s/clickhouse/clickhouse-cluster.yaml`
- `k8s/coroot/coroot-values.yaml`

Then reapply or upgrade:
```bash
helm upgrade victoria-metrics-cluster vm/victoria-metrics-cluster \
  -n victoria-metrics \
  -f k8s/victoriametrics/victoria-metrics-cluster-values.yaml

kubectl apply -f k8s/clickhouse/clickhouse-cluster.yaml

helm upgrade coroot coroot/coroot \
  -n monitoring \
  -f k8s/coroot/coroot-values.yaml
```

### Configure Data Retention

#### VictoriaMetrics Retention

Edit `k8s/victoriametrics/victoria-metrics-cluster-values.yaml`:
```yaml
vmstorage:
  retentionPeriod: "60d"  # Change to desired retention
```

#### ClickHouse Retention

Configure TTL in ClickHouse tables (done via Coroot UI or manually).

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -n <namespace>

# Describe pod
kubectl describe pod <pod-name> -n <namespace>

# Check logs
kubectl logs <pod-name> -n <namespace>

# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

### Node Agents Not Collecting Data

```bash
# Check privileged mode
kubectl get pods -n monitoring -l app.kubernetes.io/name=coroot-node-agent -o yaml | grep privileged

# Check host paths
kubectl describe pod -n monitoring -l app.kubernetes.io/name=coroot-node-agent

# Check logs
kubectl logs -n monitoring -l app.kubernetes.io/name=coroot-node-agent
```

### VictoriaMetrics Connection Issues

```bash
# Test vminsert
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -v http://vminsert-victoria-metrics-cluster.victoria-metrics.svc:8480/health

# Test vmselect
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -v http://vmselect-victoria-metrics-cluster.victoria-metrics.svc:8481/health
```

### ClickHouse Connection Issues

```bash
# Test connection
kubectl exec -it -n clickhouse chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \
  clickhouse-client --user=coroot --password=coroot123 --query="SELECT 1"

# Check ClickHouse logs
kubectl logs -n clickhouse chi-coroot-clickhouse-coroot-cluster-0-0-0
```

### Storage Issues

```bash
# Check PVCs
kubectl get pvc -n victoria-metrics
kubectl get pvc -n clickhouse
kubectl get pvc -n monitoring

# Check storage class
kubectl get storageclass

# Describe PVC
kubectl describe pvc <pvc-name> -n <namespace>
```

## Maintenance

### Backup

#### VictoriaMetrics Backup

```bash
# Using volume snapshots
gcloud compute disks snapshot <disk-name> \
  --snapshot-names=vmstorage-backup-$(date +%Y%m%d) \
  --zone=<zone>
```

#### ClickHouse Backup

```bash
# Install clickhouse-backup
kubectl exec -it -n clickhouse chi-coroot-clickhouse-coroot-cluster-0-0-0 -- bash

# Inside pod:
clickhouse-backup create backup-$(date +%Y%m%d)
clickhouse-backup list
```

### Upgrade

#### Upgrade VictoriaMetrics

```bash
helm repo update
helm upgrade victoria-metrics-cluster vm/victoria-metrics-cluster \
  -n victoria-metrics \
  -f k8s/victoriametrics/victoria-metrics-cluster-values.yaml
```

#### Upgrade ClickHouse

Check [Altinity ClickHouse Operator documentation](https://github.com/Altinity/clickhouse-operator) for upgrade procedures.

#### Upgrade Coroot

```bash
helm repo update
helm upgrade coroot coroot/coroot \
  -n monitoring \
  -f k8s/coroot/coroot-values.yaml
```

### Scaling

#### Scale VictoriaMetrics

Edit `k8s/victoriametrics/victoria-metrics-cluster-values.yaml`:
```yaml
vmselect:
  replicaCount: 3  # Increase replicas

vmstorage:
  replicaCount: 5  # Add more storage nodes
```

Apply changes:
```bash
helm upgrade victoria-metrics-cluster vm/victoria-metrics-cluster \
  -n victoria-metrics \
  -f k8s/victoriametrics/victoria-metrics-cluster-values.yaml
```

#### Scale ClickHouse

Edit `k8s/clickhouse/clickhouse-cluster.yaml`:
```yaml
shardsCount: 3  # Add more shards
```

Apply changes:
```bash
kubectl apply -f k8s/clickhouse/clickhouse-cluster.yaml
```

#### Scale Coroot

```bash
kubectl scale deployment coroot -n monitoring --replicas=3
```

## Security Hardening

### 1. Change Default Passwords

- Coroot admin password (via UI)
- ClickHouse coroot user password
- PostgreSQL password

### 2. Enable Network Policies

```yaml
# Example network policy for Coroot
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: coroot-netpol
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: coroot
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: victoria-metrics
    - namespaceSelector:
        matchLabels:
          name: clickhouse
```

### 3. Enable TLS

- Configure Ingress with cert-manager
- Enable TLS for ClickHouse connections
- Enable mutual TLS between components

### 4. Use Workload Identity

Configure GKE Workload Identity for pods to access GCP services:

```bash
# Create service account
gcloud iam service-accounts create coroot-sa

# Bind to Kubernetes service account
kubectl annotate serviceaccount coroot \
  -n monitoring \
  iam.gke.io/gcp-service-account=coroot-sa@$PROJECT_ID.iam.gserviceaccount.com

# Grant IAM binding
gcloud iam service-accounts add-iam-policy-binding \
  coroot-sa@$PROJECT_ID.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:$PROJECT_ID.svc.id.goog[monitoring/coroot]"
```

### 5. Enable Pod Security Standards

```bash
# Label namespace with restricted policy
kubectl label namespace monitoring \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

## Next Steps

1. Configure Coroot projects and dashboards
2. Set up alerting rules
3. Integrate with existing applications
4. Configure SLO-based alerting
5. Explore AI-powered root cause analysis

For more information, visit:
- [Coroot Documentation](https://docs.coroot.com/)
- [VictoriaMetrics Documentation](https://docs.victoriametrics.com/)
- [ClickHouse Documentation](https://clickhouse.com/docs/)
