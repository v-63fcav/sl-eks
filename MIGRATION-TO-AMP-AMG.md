# Migration Guide: Helm Prometheus → AWS Managed Services

## Overview

This guide documents the migration from helm-based Prometheus/Grafana to Amazon Managed Prometheus (AMP) + Amazon Managed Grafana (AMG).

## What Changed

### Removed (Deprecated)
- ❌ `helm_release.prometheus_stack` - kube-prometheus-stack chart
- ❌ `helm_release.metrics_server` - Will be re-enabled separately
- ❌ Prometheus PVCs (EBS volumes)
- ❌ Prometheus pods in cluster

### Added (New)
- ✅ `aws_prometheus_workspace.main` - AMP workspace
- ✅ `aws_grafana_workspace.main` - AMG workspace  
- ✅ `helm_release.adot_collector` - ADOT collector
- ✅ `helm_release.blackbox` - Blackbox exporter (re-enabled)
- ✅ `aws_iam_role.adot_collector_role` - IRSA for ADOT
- ✅ `aws_iam_role.amg_role` - IAM role for AMG

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  Amazon Managed Services               │
├─────────────────────────────────────────────────────────────┤
│  Amazon Managed Prometheus (AMP)                        │
│  - S3 Storage (15-day retention)                    │
│  - 99.9% SLA                                      │
│  - Auto-scaling                                      │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ Remote Write
                     │
┌────────────────────▼────────────────────────────────────┐
│              EKS Cluster                              │
├────────────────────────────────────────────────────────────┤
│  ADOT Collector (2 replicas)                         │
│  ┌──────────────────────────────────────────────┐      │
│  │ Prometheus Receiver                      │      │
│  │ - Scrapes:                              │      │
│  │   • kube-state-metrics                   │      │
│  │   • node-exporter                        │      │
│  │   • blackbox-exporter                   │      │
│  │   • kubelet                              │      │
│  └──────────────────────────────────────────────┘      │
│  ┌──────────────────────────────────────────────┐      │
│  │ K8s Cluster Receiver                 │      │
│  │ - Node metrics                            │      │
│  │ - Pod metrics                             │      │
│  └──────────────────────────────────────────────┘      │
│  ┌──────────────────────────────────────────────┐      │
│  │ Prometheus Remote Write Exporter        │      │
│  │ - Sends to AMP endpoint                  │      │
│  └──────────────────────────────────────────────┘      │
└────────────────────────────────────────────────────────────┘
                     │
                     │ Query
                     │
┌────────────────────▼────────────────────────────────────┐
│      Amazon Managed Grafana (AMG)                     │
├────────────────────────────────────────────────────────────┤
│  - IAM authentication                                │
│  - AMP datasource (pre-configured)                     │
│  - 1 user (admin)                                  │
└────────────────────────────────────────────────────────────┘
```

## Deployment Steps

### 1. Apply Infrastructure Changes

```bash
# Apply EKS infrastructure (ADOT role, outputs)
cd eks-study/infra
terraform plan
terraform apply
```

### 2. Deploy AMP and AMG

```bash
# Create AMP and AMG workspaces
cd ../apps
terraform plan
terraform apply
```

### 3. Verify AMP Workspace

```bash
# Check AMP workspace
aws amp list-workspaces

# Get workspace details
aws amp describe-workspace --workspace-id <workspace-id>

# Check logs
aws amp list-rule-groups --workspace-id <workspace-id>
```

### 4. Verify AMG Workspace

```bash
# Get AMG workspace URL
terraform output -raw amg_workspace_url

# Access via AWS Console
# Search for "Grafana" in AWS Console
# Click on "eks-study-grafana" workspace
```

### 5. Verify ADOT Collector

```bash
# Check ADOT pods
kubectl get pods -n observability -l app.kubernetes.io/name=adot-collector

# Check ADOT logs
kubectl logs -n observability -l app.kubernetes.io/name=adot-collector -f

# Check metrics are being sent
kubectl port-forward -n observability svc/adot-collector 18888:18888
# Access: http://localhost:18888/metrics
```

### 6. Verify Metrics in AMP

```bash
# Query AMP
aws amp query-metrics \
  --workspace-id <workspace-id> \
  --query "up" \
  --start-time $(date -u -d '5 minutes' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ)
```

### 7. Access Grafana

```bash
# Get AMG URL
AMG_URL=$(terraform output -raw amg_workspace_url)

# Open in browser
echo "Access Grafana at: $AMG_URL"
```

## Authentication (IAM)

AMG uses AWS IAM for authentication:

1. **Sign in to AMG**
   - Navigate to AMG workspace URL
   - Click "Sign in with AWS IAM Identity Center" or "Sign in with IAM"

2. **Grant Access**
   - EKS admin principal (you) has full access
   - To add more users, update `amg_role` in `amg.tf`

3. **Create Grafana API Key** (for automation)
   - Go to Configuration → API Keys
   - Create new key
   - Store securely

## Cleaning Up Old Resources

### Delete Prometheus Helm Release

```bash
# If old release still exists
helm uninstall prometheus-stack -n prometheus-stack

# Delete namespace
kubectl delete namespace prometheus-stack

# Delete PVCs
kubectl delete pvc -n prometheus-stack --all
```

### Delete EBS Volumes

```bash
# List EBS volumes
aws ec2 describe-volumes \
  --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=prometheus-stack

# Delete volumes (replace <volume-id>)
aws ec2 delete-volume --volume-id <volume-id>
```

## Monitoring Configuration

### Scrape Targets

ADOT collector scrapes:
- `kube-state-metrics` - Kubernetes state metrics
- `node-exporter` - Node hardware metrics
- `blackbox-exporter` - Network latency
- `kubelet` - Node-level metrics

### Custom Scraping

To add scrape targets, edit `eks-study/apps/values/values-adot.yaml`:

```yaml
receivers:
  prometheus/agent:
    config:
      scrape_configs:
        - job_name: 'custom-app'
          static_configs:
            - targets: ['myapp-service:8080']
```

### Blackbox Exporter

Blackbox exporter is deployed in `observability` namespace and scraped by ADOT.

Current config:
```yaml
- job_name: 'blackbox-exporter'
  scrape_interval: 30s
  metrics_path: /metrics
```

## Costs

### AMP
- **Ingestion**: $0.0226 per GB/month
- **Storage**: $0.0226 per GB/month (included in ingestion)
- **15-day retention**: Configured

### AMG
- **Workspace**: $9/month
- **Users**: $9 per user/month (1 user = $9/month)
- **Total**: ~$18/month + AMP costs

### Estimated Monthly Cost
| Service | Cost | Notes |
|----------|-------|-------|
| AMP | $5-20 | Based on metric volume |
| AMG | $18 | 1 user |
| **Total** | **$23-38** | ~$23-38/month |

**Previous (Helm) Cost**: EBS volumes only (~$10-20/month)

## Troubleshooting

### ADOT Not Sending Metrics

```bash
# Check ADOT logs for errors
kubectl logs -n observability deployment/adot-collector

# Check IRSA is configured
kubectl describe sa -n observability adot-collector

# Verify IAM role exists
aws iam get-role --role-name AmazonEKS_ADOT_CollectorRole
```

### AMG Not Connecting to AMP

```bash
# Check AMG datasource configuration
aws grafana list-workspace-data-sources --workspace-id <amg-workspace-id>

# Verify AMP permissions
aws iam get-role-policy --role-name amg-role-eks-study --policy-name AmazonPrometheusQueryAccess
```

### Metrics Not Showing in Grafana

```bash
# Verify data in AMP
aws amp query-metrics --workspace-id <workspace-id> --query "up"

# Check time range in Grafana
# Default is "Last 5 minutes", adjust as needed

# Verify datasource is selected
# Top-left dropdown should show "amp"
```

## Dashboards

AMG starts with default dashboards. To create custom dashboards:

1. **Import from JSON**
   - Go to Dashboards → Import
   - Upload JSON file
   - Select "amp" datasource

2. **Create New Dashboard**
   - Go to Dashboards → New
   - Add panel
   - Select "amp" datasource
   - Write PromQL query

3. **Example Queries**
   ```promql
   # CPU usage
   sum(rate(container_cpu_usage_seconds_total{namespace="default"}[5m])) by (pod)
   
   # Memory usage
   sum(container_memory_working_set_bytes{namespace="default"}) by (pod)
   
   # Node status
   kube_node_status_condition{condition="Ready", status="true"}
   ```

## Next Steps

1. ✅ Deploy infrastructure
2. ✅ Verify AMP/AMG workspaces
3. ✅ Verify ADOT is sending metrics
4. ⬜ Create dashboards in AMG
5. ⬜ Configure alerts in AMP/AMG
6. ⬜ Clean up old Prometheus resources
7. ⬜ Update documentation

## Resources

- [AMP Documentation](https://docs.aws.amazon.com/prometheus/)
- [AMG Documentation](https://docs.aws.amazon.com/grafana/)
- [ADOT Documentation](https://aws-otel.github.io/docs/)
- [AMP Pricing](https://aws.amazon.com/prometheus/pricing/)