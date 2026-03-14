# EKS Study — Apps Layer

This directory contains the Terraform configuration that installs all Kubernetes workloads onto the EKS cluster produced by the `infra/` layer. Everything is deployed via Helm releases or native Kubernetes resources. The stack forms a complete observability platform (metrics, logs, traces) plus sample applications.

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
                (gateway — OTLP + Zipkin in, fan-out)
                    ▲                  ▲
          ┌─────────┘                  └─────────────┐
    otel-test-app                               node-ws
    Zipkin (fake-service)              OTel Operator auto-inject
                                       (otel-platform CR)
```

Traffic from the internet reaches applications and Grafana through the **AWS Load Balancer Controller**, which provisions ALBs from `Ingress` resources.

For a full trace data-flow diagram see [README-otel.md](README-otel.md).

---

## Services

### AWS Load Balancer Controller

| | |
|---|---|
| Chart | `aws/aws-load-balancer-controller` |
| Namespace | `kube-system` |
| Values | [values/values-alb-controller.yaml](values/values-alb-controller.yaml) |

Watches `Ingress` resources with `ingressClassName: alb` and provisions AWS Application Load Balancers automatically. Uses IRSA (IAM Roles for Service Accounts) so no static credentials are needed — the IRSA role ARN is injected at deploy time from the `infra/` outputs.

**How to use:** annotate any `Ingress` with `ingressClassName: alb`. The controller creates and manages the ALB lifecycle.

---

### kube-prometheus-stack

| | |
|---|---|
| Chart | `prometheus-community/kube-prometheus-stack` v69.3.1 |
| Namespace | `monitoring` |
| Values | [values/values-kube-prometheus-stack.yaml](values/values-kube-prometheus-stack.yaml) |

Umbrella chart that installs:

- **Prometheus** — scrapes metrics from all `ServiceMonitor` and `PodMonitor` resources cluster-wide. Retention: 15 days / 40 GiB. Storage: 50 GiB gp3.
- **Grafana** — pre-loaded with EKS dashboards, Loki datasource, and Tempo datasource (with trace-to-log correlation). Exposed via an internet-facing ALB on port 80. Default credentials: `admin / changeme`.
- **Alertmanager** — receives firing alerts from Prometheus. Storage: 10 GiB gp3.
- **Prometheus Operator** — watches for `ServiceMonitor`/`PodMonitor` CRDs and configures Prometheus scrape targets dynamically.
- **Node Exporter** — DaemonSet; exposes host-level CPU, memory, disk, and network metrics from each node.
- **kube-state-metrics** — exposes Kubernetes object state metrics (pod restarts, deployment replicas, etc.).

**How to use:**
1. Get the Grafana ALB hostname: `kubectl get ingress -n monitoring`
2. Open it in a browser and log in with `admin / changeme`.
3. To add a scrape target for your own service, create a `ServiceMonitor` in any namespace — Prometheus discovers them everywhere (`serviceMonitorSelectorNilUsesHelmValues: false`).

---

### Loki

| | |
|---|---|
| Chart | `grafana/loki` v6.29.0 |
| Namespace | `monitoring` |
| Values | [values/values-loki.yaml](values/values-loki.yaml) |

Log aggregation backend. Deployed in **SingleBinary** mode (all components in one pod), suitable for dev/staging. Storage: 20 GiB gp3. Schema: TSDB v13.

Loki is a passive backend — it only stores logs that are pushed to it. Log collection is handled by **Promtail**.

**How to use:**
1. Open Grafana → Explore → select the **Loki** datasource.
2. Filter by namespace: `{namespace="default"}`
3. Filter by pod: `{pod=~"node-ws.*"}` or `{pod=~"otel-test-app.*"}`
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

Distributed tracing backend. Receives traces over **OTLP gRPC (:4317)** and **OTLP HTTP (:4318)**. Retention: 24 hours. Storage: 20 GiB gp3.

Applications do **not** send traces directly to Tempo — they send to the **OTel Collector**, which forwards to Tempo. This decouples apps from the backend.

The Grafana Tempo datasource is pre-configured with **trace-to-logs correlation**: clicking a span automatically jumps to the matching Loki logs for that pod and time window.

**How to use:**
1. Open Grafana → Explore → select the **Tempo** datasource.
2. Search by service name, trace ID, or use the **Search** tab to filter by duration, status, or tags.
3. Click any span to inspect attributes and jump to correlated Loki logs.

---

### OpenTelemetry Collector

| | |
|---|---|
| Chart | `open-telemetry/opentelemetry-collector` v0.118.0 |
| Namespace | `monitoring` |
| Image | `otel/opentelemetry-collector-contrib` |
| Values | [values/values-otel-collector.yaml](values/values-otel-collector.yaml) |

Gateway-mode `Deployment` that acts as the central telemetry hub. Accepts OTLP and Zipkin from applications and fans out to all three backends:

| Signal | Receivers | Exporter | Backend |
|---|---|---|---|
| Traces | OTLP gRPC/HTTP, Zipkin | `otlp/tempo` | Tempo `:4317` |
| Metrics | OTLP gRPC/HTTP | `prometheusremotewrite` | Prometheus `:9090` |
| Logs | OTLP gRPC/HTTP | `loki` | Loki `:3100` |

Processors in every pipeline: `memory_limiter` (75% limit, 20% spike cap) → `batch` (5s timeout, 1000 items).

```
OTLP gRPC:  opentelemetry-collector.monitoring.svc.cluster.local:4317
OTLP HTTP:  opentelemetry-collector.monitoring.svc.cluster.local:4318
Zipkin:     opentelemetry-collector.monitoring.svc.cluster.local:9411
```

---

### OpenTelemetry Operator

| | |
|---|---|
| Chart | `open-telemetry/opentelemetry-operator` (latest) |
| Namespace | `opentelemetry-operator-system` |
| Values | [values/values-otel-operator.yaml](values/values-otel-operator.yaml) |

Kubernetes operator that enables **zero-code auto-instrumentation** via a mutating admission webhook. When a pod is created with an inject annotation, the operator patches its spec to add an init container that downloads the language-specific OTel SDK and sets `NODE_OPTIONS` (or equivalent) so the SDK loads automatically at runtime.

Supported languages: Node.js, Java, Python, Go, .NET.

No cert-manager required — the operator generates its own self-signed webhook certificate via `autoGenerateCert`.

**How to instrument an app:**
1. Ensure a matching `Instrumentation` CR exists in the same namespace (see otel-platform below).
2. Add the annotation to the pod:
   ```yaml
   instrumentation.opentelemetry.io/inject-nodejs: "nodejs"
   ```
3. Set `OTEL_SERVICE_NAME` as a pod env var — this is app-specific and is not part of the shared CR.

---

### otel-platform

| | |
|---|---|
| Chart | local `./otel-platform-chart` |
| Namespace | `default` |
| Values | [otel-platform-chart/values.yaml](otel-platform-chart/values.yaml) |

Deploys namespace-wide `Instrumentation` CRs shared by all applications in the `default` namespace. Decoupled from individual app charts so that adding a new app requires no changes to the platform layer.

| CR name | Language | Referenced by |
|---|---|---|
| `nodejs` | Node.js | `inject-nodejs: "nodejs"` annotation |

`OTEL_SERVICE_NAME` is **not** set in the CR — each app sets it as a pod env var, giving every service a distinct name in Tempo without needing a separate CR per app.

---

### node-ws

| | |
|---|---|
| Chart | local `./app-chart` |
| Namespace | `default` |
| Values | [app-chart/values.yaml](app-chart/values.yaml) |

Minimal Node.js (`node:20-alpine`) web server auto-instrumented by the OTel Operator. Exposed via an internet-facing ALB.

- 1 replica, HTTP on port 3000
- Resource requests: 100m CPU / 128Mi memory; limits: 500m CPU / 256Mi memory
- Traces visible in Grafana → Tempo → `service.name = node-ws`

The `app-chart` is app-agnostic — the app name, service name, and image are all driven from `values.yaml`. To deploy a second Node.js app, copy the `helm_release` block in [helm.tf](helm.tf) and override `nameOverride` and `otel.serviceName`.

---

### otel-test-app

| | |
|---|---|
| Chart | local `./otel-test-app-chart` |
| Namespace | `default` |
| Values | [otel-test-app-chart/values.yaml](otel-test-app-chart/values.yaml) |

Pre-built Go HTTP service (`nicholasjackson/fake-service:v0.26.2`) used to generate realistic traces without writing application code. Ships with built-in Zipkin tracing — spans are sent to the OTel Collector on `:9411`, which translates them to OTLP and forwards to Tempo.

- Exposed via internet-facing ALB on port 80
- Traces visible in Grafana → Tempo → `service.name = otel-test-app`
- Endpoints: `/` (generates a trace), `/health` (ALB health check)

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
terraform init   # needed after adding the time provider
terraform apply
```

After `terraform apply`:
1. `kubectl get ingress -n default` — get ALB URLs for node-ws and otel-test-app
2. `kubectl get ingress -n monitoring` — get the Grafana ALB URL
3. Log into Grafana (`admin / changeme`) and verify all three datasources (Prometheus, Loki, Tempo) show green
4. Check Prometheus targets: Grafana → Explore → Prometheus → `up` — all targets should be `1`
5. Send requests to the app ALBs to generate traces, then search in Grafana → Explore → Tempo
