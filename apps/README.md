# EKS Study — Apps Layer

This directory contains the Terraform configuration that installs all Kubernetes workloads onto the EKS cluster produced by the `infra/` layer. Everything is deployed via Helm releases or native Kubernetes resources. The stack forms a complete observability platform (metrics, logs, traces) plus a sample application.

## Architecture overview

```
                    ┌─────────────┐
                    │   Grafana   │  ← single UI for all signals
                    └──────┬──────┘
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
      Prometheus          Loki           Tempo
      (metrics)          (logs)         (traces)
           ▲               ▲               ▲
           │        ┌──────┘               │
           │        │  Promtail            │
           │        │  (DaemonSet)         │
           └────────┴──────────────────────┘
                    OTel Collector
              (gateway — OTLP in, fan-out)
                         ▲
                    Your applications
                    (OTLP push)
```

Traffic from the internet reaches Grafana through the **AWS Load Balancer Controller**, which provisions an ALB from the Grafana `Ingress` resource.

---

## Services

### AWS Load Balancer Controller

| | |
|---|---|
| Chart | `aws/aws-load-balancer-controller` |
| Namespace | `kube-system` |
| Values | [values/values-alb-controller.yaml](values/values-alb-controller.yaml) |

Watches `Ingress` resources with `ingressClassName: alb` and provisions AWS Application Load Balancers automatically. Uses IRSA (IAM Roles for Service Accounts) so no static credentials are needed — the IRSA role ARN is injected at deploy time from the `infra/` outputs.

**How to use:** annotate any `Ingress` with `kubernetes.io/ingress.class: alb` (or set `ingressClassName: alb`). The controller will create and manage the ALB lifecycle.

---

### kube-prometheus-stack

| | |
|---|---|
| Chart | `prometheus-community/kube-prometheus-stack` v69.3.1 |
| Namespace | `monitoring` |
| Values | [values/values-kube-prometheus-stack.yaml](values/values-kube-prometheus-stack.yaml) |

Umbrella chart that installs:

- **Prometheus** — scrapes metrics from all `ServiceMonitor` and `PodMonitor` resources cluster-wide. Retention: 15 days / 40 GiB. Storage: 50 GiB gp3.
- **Grafana** — pre-loaded with EKS dashboards, Loki datasource, and Tempo datasource (with trace-to-log correlation). Exposed via an internet-facing ALB on port 80. Default credentials: `admin / changeme` — change this before going to production.
- **Alertmanager** — receives firing alerts from Prometheus. Storage: 10 GiB gp3.
- **Prometheus Operator** — watches for `ServiceMonitor`/`PodMonitor` CRDs and configures Prometheus scrape targets dynamically.
- **Node Exporter** — DaemonSet; exposes host-level CPU, memory, disk, and network metrics from each node.
- **kube-state-metrics** — exposes Kubernetes object state metrics (pod restarts, deployment replicas, etc.).

**How to use:**
1. Get the Grafana ALB hostname: `kubectl get ingress -n monitoring`
2. Open it in a browser and log in with `admin / changeme`.
3. To add a scrape target for your own service, create a `ServiceMonitor` in any namespace — Prometheus is configured to discover them everywhere (`serviceMonitorSelectorNilUsesHelmValues: false`).

---

### Loki

| | |
|---|---|
| Chart | `grafana/loki` v6.29.0 |
| Namespace | `monitoring` |
| Values | [values/values-loki.yaml](values/values-loki.yaml) |

Log aggregation backend. Deployed in **SingleBinary** mode (all components — ingester, querier, compactor — in one pod), which is appropriate for dev/staging. Storage: 20 GiB gp3 on the local filesystem. Schema: TSDB v13.

Loki is a passive backend — it only stores logs that are pushed to it. Log collection is handled by **Promtail** (see below).

**How to use:**
1. Open Grafana → Explore → select the **Loki** datasource.
2. Filter by namespace: `{namespace="default"}`
3. Filter by pod: `{pod=~"node-ws.*"}`
4. Combine with a text search: `{namespace="monitoring"} |= "error"`

> For production, switch `deploymentMode` to `SimpleScalable` or `Distributed` and use S3 for object storage.

---

### Promtail

| | |
|---|---|
| Chart | `grafana/promtail` (latest) |
| Namespace | `monitoring` |
| Values | inline `set` in [helm.tf](helm.tf) |

DaemonSet that runs on every node and tails all container logs from `/var/log/pods/`. Automatically attaches Kubernetes metadata labels (`namespace`, `pod`, `container`, `node`, `app`) as Loki stream labels, making every pod's logs queryable in Grafana without any per-app configuration.

Logs are pushed to: `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`

**How to use:** nothing to configure per application — all stdout/stderr from all namespaces is collected automatically the moment Promtail is running.

---

### Tempo

| | |
|---|---|
| Chart | `grafana/tempo` v1.14.0 |
| Namespace | `monitoring` |
| Values | [values/values-tempo.yaml](values/values-tempo.yaml) |

Distributed tracing backend. Receives traces over **OTLP gRPC (4317)** and **OTLP HTTP (4318)**. Retention: 24 hours. Storage: 20 GiB gp3.

In this stack, applications do **not** send traces directly to Tempo. They send to the **OTel Collector**, which forwards to Tempo. This decouples apps from the backend.

The Grafana datasource for Tempo is pre-configured with **trace-to-logs correlation**: clicking a span in a trace automatically jumps to the matching log lines in Loki for that pod and time window.

**How to use:**

1. **Instrument your app** with any OpenTelemetry SDK (Go, Python, Node.js, Java, etc.) and configure the OTLP exporter to point at the collector:
   ```
   OTEL_EXPORTER_OTLP_ENDPOINT=http://opentelemetry-collector.monitoring.svc.cluster.local:4317
   OTEL_SERVICE_NAME=my-service
   ```
2. Open Grafana → Explore → select the **Tempo** datasource.
3. Search by service name, trace ID, or use **Search** tab to filter by duration, status, or tags.
4. Click any span to inspect attributes, see child spans, and jump to correlated Loki logs.

---

### OpenTelemetry Collector

| | |
|---|---|
| Chart | `open-telemetry/opentelemetry-collector` v0.118.0 |
| Namespace | `monitoring` |
| Image | `otel/opentelemetry-collector-contrib` |
| Values | [values/values-otel-collector.yaml](values/values-otel-collector.yaml) |

Gateway-mode `Deployment` (1 replica) that acts as a central telemetry hub. Accepts OTLP from applications and fans out to the three backends:

| Signal | Receiver | Exporter | Backend |
|---|---|---|---|
| Metrics | OTLP gRPC/HTTP | `prometheusremotewrite` | Prometheus `:9090` |
| Traces | OTLP gRPC/HTTP | `otlp/tempo` | Tempo `:4317` |
| Logs | OTLP gRPC/HTTP | `loki` | Loki `:3100` |

Processors in pipeline: `memory_limiter` (75% limit, 20% spike cap) → `batch` (5 s timeout, 1000 items).

A `ServiceMonitor` is enabled so Prometheus scrapes the collector's own metrics.

**How to use:**
```
OTLP gRPC:  opentelemetry-collector.monitoring.svc.cluster.local:4317
OTLP HTTP:  opentelemetry-collector.monitoring.svc.cluster.local:4318
```

Point your OTel SDK exporter at either endpoint. The collector handles routing to all backends automatically.

---

### node-ws

| | |
|---|---|
| Chart | local `./app-chart` |
| Namespace | `default` |
| Values | [app-chart/values.yaml](app-chart/values.yaml) |

A minimal Node.js (`20-alpine`) web server auto-instrumented by the OTel Operator. Ships with:

- 1 replica, HTTP on port 3000
- A 5 GiB gp3 `PersistentVolumeClaim` mounted at `/data`
- Resource requests: 250m CPU / 256Mi memory; limits: 500m CPU / 512Mi memory

**How to use:** override `values.yaml` fields in [helm.tf](helm.tf) via `set {}` blocks to swap the image or adjust resources for your own workload.

---

## Infrastructure dependencies

| Resource | File | Purpose |
|---|---|---|
| `kubernetes_storage_class_v1.gp3` | [k8s-resources.tf](k8s-resources.tf) | gp3 EBS StorageClass (encrypted, `Retain`, `WaitForFirstConsumer`) used by all PVCs |

All Helm releases that create PVCs depend on this StorageClass being present first.

---

## Deployment

```bash
# From the infra/ directory first
cd infra && terraform apply

# Then deploy apps
cd ../apps
terraform init
terraform apply
```

After `terraform apply`:
1. `kubectl get ingress -n monitoring` — get the Grafana ALB URL
2. Log into Grafana (admin / changeme) and verify all three datasources (Prometheus, Loki, Tempo) show green
3. Check Prometheus targets: Grafana → Explore → Prometheus → `up` — all targets should be `1`
