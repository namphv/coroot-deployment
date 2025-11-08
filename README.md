# Coroot Monitoring System on GKE

A complete deployment solution for [Coroot](https://coroot.com) observability platform on Google Kubernetes Engine (GKE) with **unified ClickHouse storage** for all observability data.

## 🎯 Overview

This repository provides Infrastructure as Code (IaC) and deployment scripts for running Coroot with:

- **Unified ClickHouse storage** for metrics, logs, traces, and profiling data
- **No VictoriaMetrics/Prometheus needed** - ClickHouse handles everything
- **GKE cluster** with spot nodes for cost optimization (80-90% spot usage)
- **High availability** configuration with multi-zone deployment
- **Production-ready** security and monitoring configurations

## 🏗️ Simplified Architecture

```
GKE Cluster
├── Monitoring/Storage Node Pool (Regular) - Critical infrastructure
└── Spot Node Pool (Preemptible) - Application + ClickHouse workers

Components:
├── ClickHouse Cluster (clickhouse namespace)
│   ├── ClickHouse Keeper (3 replicas) - Coordination
│   ├── Anchor nodes (2 on-demand) - Hot data, guaranteed availability
│   └── Worker nodes (6-12 spot) - All data, scale-out capacity
└── Coroot (monitoring namespace)
    ├── Coroot Server (2 replicas) - Web UI & Analysis
    ├── PostgreSQL (1 replica) - Metadata storage
    └── Node Agents (DaemonSet) - eBPF data collection

Data Flow:
Coroot Agents → Coroot Server → ClickHouse
                                  ├─ Metrics
                                  ├─ Logs
                                  ├─ Traces
                                  └─ Profiles
```

### Why ClickHouse for Everything?

✅ **Simpler**: One storage system instead of two (ClickHouse + VictoriaMetrics)
✅ **Cheaper**: Save $300-400/month by eliminating VictoriaMetrics
✅ **Native Support**: Coroot has built-in ClickHouse metrics support
✅ **Unified Queries**: Query metrics + logs + traces together
✅ **Efficient**: 10-100x compression for time-series metrics
✅ **Still Spot-Optimized**: 60%+ cost savings with spot nodes

See [UNIFIED_CLICKHOUSE_ARCHITECTURE.md](./UNIFIED_CLICKHOUSE_ARCHITECTURE.md) for detailed design.

## 📋 Prerequisites

- GCP Project with billing enabled
- `gcloud` CLI installed and configured
- `kubectl` (version 1.25+)
- `helm` (version 3.10+)
- `terraform` (version 1.5+) - optional

## 🚀 Quick Start

### 1. Clone Repository

```bash
git clone <repository-url>
cd coroot-deployment
```

### 2. Set Environment Variables

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-central1"
export CLUSTER_NAME="coroot-monitoring-cluster"

gcloud config set project $PROJECT_ID
```

### 3. Deploy GKE Cluster

**Option A: Using Terraform**

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply

# Get credentials
$(terraform output -raw get_credentials_command)
```

**Option B: Using gcloud Script**

```bash
cd scripts
./create-gke-cluster.sh
```

### 4. Deploy Monitoring Stack

```bash
# Install ClickHouse (with ClickHouse Keeper)
./install-clickhouse.sh

# Install Coroot (configured for ClickHouse metrics)
./install-coroot.sh
```

### 5. Access Coroot

```bash
# Get service details
kubectl get svc -n monitoring coroot

# If using LoadBalancer, access via external IP
# If using ClusterIP, use port-forward:
kubectl port-forward -n monitoring svc/coroot 8080:8080
```

Open http://localhost:8080 (or LoadBalancer IP) in your browser.

**Default credentials:**
- Username: `admin`
- Password: `admin` (⚠️ Change immediately!)

## 📁 Repository Structure

```
coroot-deployment/
├── README.md                              # This file
├── UNIFIED_CLICKHOUSE_ARCHITECTURE.md    # Unified ClickHouse design
├── CLICKHOUSE_SPOT_ARCHITECTURE.md       # Spot node optimization details
├── DEPLOYMENT_GUIDE.md                   # Step-by-step deployment guide
├── terraform/                            # Terraform IaC for GKE cluster
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── k8s/                                  # Kubernetes manifests
│   ├── namespaces/
│   ├── clickhouse/
│   │   ├── 00-namespace.yaml
│   │   ├── clickhouse-keeper.yaml       # ClickHouse Keeper (not ZooKeeper!)
│   │   └── clickhouse-cluster.yaml
│   └── coroot/
│       └── coroot-values.yaml           # Configured for ClickHouse metrics
└── scripts/                              # Deployment scripts
    ├── create-gke-cluster.sh
    ├── install-clickhouse.sh
    └── install-coroot.sh
```

## 📖 Documentation

- **[UNIFIED_CLICKHOUSE_ARCHITECTURE.md](./UNIFIED_CLICKHOUSE_ARCHITECTURE.md)** - Why and how to use ClickHouse for all data
- **[CLICKHOUSE_SPOT_ARCHITECTURE.md](./CLICKHOUSE_SPOT_ARCHITECTURE.md)** - Spot node optimization strategy
- **[DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md)** - Detailed deployment instructions

## 🔧 Configuration

### Resource Sizing

| Deployment Size | Nodes | ClickHouse Storage | Monthly Cost | Savings |
|----------------|-------|-------------------|--------------|---------|
| Small (Dev)    | 5-8   | 200GB, 7d         | $800         | 75%     |
| Medium (Prod)  | 11-18 | 1TB, 30d          | $1,461       | 60%     |
| Large (Ent.)   | 21-33 | 3TB, 90d          | $2,400       | 50%     |

### Customization

Edit these files to customize your deployment:

1. **GKE Cluster**: `terraform/terraform.tfvars` or `scripts/create-gke-cluster.sh`
2. **ClickHouse**: `k8s/clickhouse/clickhouse-cluster.yaml`
3. **Coroot**: `k8s/coroot/coroot-values.yaml`

### Enabling ClickHouse for Metrics (Already Done!)

The Coroot configuration includes:

```yaml
env:
  - name: GLOBAL_PROMETHEUS_USE_CLICKHOUSE
    value: "true"  # Metrics go to ClickHouse!

  - name: CLICKHOUSE_SPACE_MANAGER_ENABLED
    value: "true"  # Auto-cleanup for spot nodes
```

No VictoriaMetrics or Prometheus configuration needed!

## 🔐 Security Considerations

⚠️ **Important Security Steps:**

1. **Change default passwords:**
   - Coroot admin password (via UI)
   - ClickHouse user password
   - PostgreSQL password

2. **Enable TLS:**
   - Configure Ingress with cert-manager
   - Enable TLS for inter-component communication

3. **Network policies:**
   - Restrict traffic between namespaces
   - Implement least-privilege access

4. **Secrets management:**
   - Use Google Secret Manager or Sealed Secrets
   - Never commit secrets to Git

See [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md#security-hardening) for detailed security hardening steps.

## 🛠️ Troubleshooting

### Common Issues

**Pods not starting:**
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

**Metrics not showing:**
```bash
# Check Coroot logs
kubectl logs -n monitoring -l app.kubernetes.io/name=coroot

# Verify ClickHouse connectivity
kubectl exec -it -n clickhouse chi-coroot-clickhouse-coroot-cluster-0-0-0 -- \
  clickhouse-client --user=coroot --password=coroot123 --query="SHOW DATABASES"
```

**Storage issues:**
```bash
kubectl get pvc -A
kubectl describe pvc <pvc-name> -n <namespace>
```

See [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md#troubleshooting) for more troubleshooting tips.

## 📊 Monitoring and Maintenance

### Verify Deployment

```bash
# Check all components
kubectl get pods -n clickhouse
kubectl get pods -n monitoring

# Check resource usage
kubectl top nodes
kubectl top pods -A
```

### Backup

```bash
# ClickHouse backup
kubectl exec -it -n clickhouse chi-coroot-clickhouse-coroot-cluster-0-0-0 -- bash
clickhouse-backup create backup-$(date +%Y%m%d)
```

### Upgrade

```bash
# Update Helm repositories
helm repo update

# Upgrade Coroot
helm upgrade coroot coroot/coroot \
  -n monitoring \
  -f k8s/coroot/coroot-values.yaml
```

## 💰 Cost Optimization

1. **Spot nodes** for ClickHouse workers (60-90% savings)
2. **Unified storage** - no duplicate VictoriaMetrics infrastructure
3. **Right-size** resources based on actual usage
4. **Configure retention** policies for data
5. **Use regional disks** instead of multi-zonal when appropriate

**Expected Costs:**

| Component | Configuration | Monthly Cost |
|-----------|--------------|--------------|
| ClickHouse Keeper | 3 × e2-micro (on-demand) | $21 |
| ClickHouse Anchors | 2 × n2-standard-8 (on-demand) | $500 |
| ClickHouse Workers | 6 × n2-highmem-8 (spot) | $240 |
| Storage | Anchors 300GB + Workers 3TB | $550 |
| Coroot + PostgreSQL | Moderate resources | $150 |
| **Total** | **Unified ClickHouse** | **$1,461/mo** |
| **vs All On-Demand** | **$3,651** | **60% savings** |

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## 📝 License

[Add your license here]

## 🔗 Resources

- [Coroot Documentation](https://docs.coroot.com/)
- [ClickHouse Documentation](https://clickhouse.com/docs/)
- [GKE Documentation](https://cloud.google.com/kubernetes-engine/docs)
- [Coroot + ClickHouse Integration](https://docs.coroot.com/configuration/clickhouse/)

## 📧 Support

For issues and questions:
- Open an issue in this repository
- Check [Coroot GitHub](https://github.com/coroot/coroot)
- Visit [Coroot Community](https://coroot.com/community)

## ✅ What's Included

- ✅ Production-ready GKE cluster configuration
- ✅ Unified ClickHouse for all observability data
- ✅ No VictoriaMetrics/Prometheus needed
- ✅ Cost-optimized spot nodes (60%+ savings)
- ✅ ClickHouse Keeper (not ZooKeeper)
- ✅ Security best practices
- ✅ Monitoring and alerting
- ✅ Backup procedures
- ✅ Comprehensive documentation

## 🎓 Next Steps

After deployment:

1. **Configure Projects** in Coroot UI
2. **Set up Dashboards** for your applications
3. **Configure Alerting** rules
4. **Integrate Applications** with Coroot agents
5. **Explore AI-powered Root Cause Analysis**

Happy monitoring! 🚀
