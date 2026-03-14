# OpenTelemetry Observability Stack

This document describes the distributed tracing setup deployed in this EKS cluster.
Two complementary instrumentation approaches are used, both routing through the same
OTel Collector and landing in Grafana Tempo.

---

## Table of Contents

1. [Overview](#overview)
2. [Stack 1 — OTel Collector (Protocol Translation)](#stack-1--otel-collector-protocol-translation)
3. [Stack 2 — OTel Operator (Auto-Instrumentation)](#stack-2--otel-operator-auto-instrumentation)
4. [Shared Backend](#shared-backend)
5. [Component Deep-Dive](#component-deep-dive)
   - [fake-service (otel-test-app)](#fake-service-otel-test-app)
   - [node-ws (app-chart)](#node-ws-app-chart)
   - [OpenTelemetry Collector](#opentelemetry-collector)
   - [OpenTelemetry Operator](#opentelemetry-operator)
   - [Tempo](#tempo)
   - [Grafana](#grafana)
6. [Pipeline Internals](#pipeline-internals)
7. [Port Reference](#port-reference)
8. [How to Test](#how-to-test)

---

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              EKS Cluster                                    │
│                                                                             │
│  STACK 1: Collector                     STACK 2: Operator                  │
│                                                                             │
│  ┌──────────────┐  Zipkin               ┌──────────────┐  OTLP/HTTP        │
│  │  fake-service│─────────────┐         │   node-ws    │──────────┐        │
│  │ (otel-test-  │  :9411      │         │  (app-chart) │  :4318   │        │
│  │    app)      │             │         │  [SDK injected           │        │
│  └──────────────┘             │         │   by Operator]│          │        │
│                               │         └──────────────┘          │        │
│                               ▼                                    ▼        │
│                    ┌──────────────────────────────────────────────────┐    │
│                    │           OpenTelemetry Collector                │    │
│                    │           (gateway, namespace: monitoring)        │    │
│                    │  receivers: zipkin :9411, otlp :4317/:4318       │    │
│                    └─────────────────────┬────────────────────────────┘    │
│                                          │  OTLP/gRPC :4317                │
│                                          ▼                                  │
│                                   ┌──────────┐                             │
│                                   │  Tempo   │                             │
│                                   └────┬─────┘                             │
│                                        │  HTTP :3100                       │
│                                        ▼                                   │
│                                   ┌──────────┐                             │
│                                   │ Grafana  │                             │
│                                   └──────────┘                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

Both stacks converge at the Collector. Traces from either app are stored in Tempo
and visible in Grafana under their respective `service.name`.

---

## Stack 1 — OTel Collector (Protocol Translation)

**App:** `otel-test-app` (fake-service)
**How instrumented:** Built-in — the image ships with Zipkin tracing enabled via an environment variable.
**Tracing protocol:** Zipkin HTTP → OTel Collector → OTLP → Tempo

```
User / curl
    │  HTTP :80 (ALB)
    ▼
┌─────────────────────────────────────────────────────┐
│  fake-service  (nicholasjackson/fake-service:v0.26.2)│
│  namespace: default                                 │
│                                                     │
│  env: NAME=otel-test-app                            │
│  env: TRACING_ZIPKIN=http://opentelemetry-          │
│       collector.monitoring:9411/api/v2/spans        │
│                                                     │
│  On each request:                                   │
│    1. Handles HTTP request                          │
│    2. Records timing and status                     │
│    3. Builds a Zipkin span                          │
│    4. POSTs span to TRACING_ZIPKIN                  │
└────────────────────────┬────────────────────────────┘
                         │  POST /api/v2/spans (Zipkin, :9411)
                         ▼
              OTel Collector (zipkin receiver)
                         │  converts Zipkin → OTLP
                         ▼
                       Tempo
```

**Why Zipkin and not OTLP?**
fake-service predates the OTLP standard. Its tracing support is built on the Zipkin
client library. Because the Collector accepts both protocols, this is not a problem —
it translates transparently and Tempo never sees Zipkin.

---

## Stack 2 — OTel Operator (Auto-Instrumentation)

**App:** `node-ws` (app-chart)
**How instrumented:** Zero-code — the OTel Operator injects the Node.js SDK at pod startup via a mutating webhook.
**Tracing protocol:** OTLP/HTTP → OTel Collector → OTLP/gRPC → Tempo

```
User / curl
    │  (ClusterIP, internal only)
    ▼
┌─────────────────────────────────────────────────────┐
│  node-ws  (node:20-alpine)                          │
│  namespace: default                                 │
│                                                     │
│  annotation:                                        │
│    instrumentation.opentelemetry.io/inject-nodejs:  │
│    "true"                                           │
│                                                     │
│  At pod startup, the Operator webhook:              │
│    1. Sees the annotation on the pod                │
│    2. Reads the Instrumentation CR                  │
│    3. Injects an init container that downloads      │
│       the Node.js OTel SDK                          │
│    4. Adds NODE_OPTIONS=--require @opentelemetry/.. │
│       so the SDK auto-patches http, dns, etc.       │
│                                                     │
│  At runtime, the SDK:                               │
│    1. Intercepts every http.createServer request    │
│    2. Creates a span with method, url, status       │
│    3. Exports via OTLP HTTP to the Collector        │
└────────────────────────┬────────────────────────────┘
                         │  OTLP/HTTP :4318
                         ▼
              OTel Collector (otlp/http receiver)
                         │  forwards as OTLP/gRPC
                         ▼
                       Tempo
```

### Instrumentation CR

The `Instrumentation` CR (deployed by the `app-chart`) is what the Operator reads
to know where to send traces and how to configure the SDK:

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: node-ws
  namespace: default
spec:
  exporter:
    endpoint: http://opentelemetry-collector.monitoring:4318
  propagators: [tracecontext, baggage]
  sampler:
    type: parentbased_traceidratio
    argument: "1"        # sample 100% of traces
  nodejs:
    env:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: http://opentelemetry-collector.monitoring:4318
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: http/protobuf
      - name: OTEL_SERVICE_NAME
        value: node-ws
```

### Why the Operator approach?

| | Collector stack | Operator stack |
|---|---|---|
| Code changes needed | None | None |
| Works with any language | No (app must speak Zipkin/OTLP) | Yes (language-specific SDK injection) |
| Trace granularity | App-level (what the app exposes) | Function/library-level (http, db, dns, etc.) |
| SDK maintenance | App's responsibility | Operator manages SDK version |
| Best for | Pre-built images with tracing built in | Standard language runtimes (Node, Java, Python) |

---

## Shared Backend

Both stacks send all traces through the same Collector, into the same Tempo instance,
and are visible in the same Grafana workspace — just filtered by `service.name`.

```
Grafana → Explore → Tempo → Search
  Service Name: otel-test-app   ← Stack 1 traces
  Service Name: node-ws         ← Stack 2 traces
```

---

## Component Deep-Dive

### fake-service (otel-test-app)

**Image:** `nicholasjackson/fake-service:v0.26.2`
**Namespace:** `default`
**Chart:** `apps/otel-test-app-chart/` (local Helm chart)

#### Key environment variables

| Variable         | Value                                                         | Purpose                                  |
|------------------|---------------------------------------------------------------|------------------------------------------|
| `NAME`           | `otel-test-app`                                               | Sets the service name reported in traces |
| `TRACING_ZIPKIN` | `http://opentelemetry-collector.monitoring:9411/api/v2/spans` | Where to POST Zipkin-format spans        |

#### Endpoints

| Path      | Description                                     |
|-----------|-------------------------------------------------|
| `/`       | Returns a JSON response; generates a trace span |
| `/health` | Health check; used by ALB and probes            |

---

### node-ws (app-chart)

**Image:** `node:20-alpine`
**Namespace:** `default`
**Chart:** `apps/app-chart/` (local Helm chart)

The application is a minimal inline Node.js HTTP server. It has no OTel SDK in its
source — the Operator injects the SDK at pod startup via `NODE_OPTIONS`.

#### Key resources

| Resource              | Name              | Purpose                                              |
|-----------------------|-------------------|------------------------------------------------------|
| Deployment annotation | `inject-nodejs`   | Triggers the Operator webhook to inject the SDK      |
| Instrumentation CR    | `node-ws`         | Tells the Operator which collector and SDK config to use |
| Init container        | `opentelemetry-auto-instrumentation-nodejs` | Copies SDK files into the pod |

#### Verify injection worked

```bash
kubectl describe pod -n default -l app.kubernetes.io/name=node-ws \
  | grep -A5 'Init Containers'
# Should show: opentelemetry-auto-instrumentation-nodejs

kubectl exec -n default deploy/node-ws-node-ws -- env | grep NODE_OPTIONS
# Should show: --require @opentelemetry/auto-instrumentations-node/register
```

---

### OpenTelemetry Collector

**Image:** `otel/opentelemetry-collector-contrib`
**Chart:** `open-telemetry/opentelemetry-collector v0.118.0`
**Namespace:** `monitoring`
**Mode:** `deployment` (gateway — one centralised instance)

The `-contrib` image is used because it includes community-contributed components:
the `zipkin` receiver and the `loki` exporter, which are not in the core distribution.

#### Receivers

```yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: "0.0.0.0:4317" }   # node-ws (Operator stack) and any OTLP app
      http: { endpoint: "0.0.0.0:4318" }   # node-ws (Operator stack)
  zipkin:
    endpoint: "0.0.0.0:9411"               # fake-service (Collector stack)
```

#### Processors

**`memory_limiter`** (runs first in every pipeline)
```yaml
memory_limiter:
  check_interval: 1s
  limit_percentage: 75       # drop data at 75% of container memory limit
  spike_limit_percentage: 20
```
Without this, a traffic spike could OOM-kill the Collector pod and lose all buffered data.

**`batch`** (runs second)
```yaml
batch:
  timeout: 5s            # send whatever is buffered after 5 seconds
  send_batch_size: 1000  # or immediately when 1000 spans accumulate
```
Batching reduces network overhead dramatically — 1 request per 1000 spans vs 1000 individual requests.

#### Pipelines

```
traces pipeline:
  receivers:  [otlp, zipkin]          ← accepts both stacks
  processors: [memory_limiter, batch]
  exporters:  [otlp/tempo]

metrics pipeline:
  receivers:  [otlp]
  processors: [memory_limiter, batch]
  exporters:  [prometheusremotewrite]

logs pipeline:
  receivers:  [otlp]
  processors: [memory_limiter, batch]
  exporters:  [loki]
```

---

### OpenTelemetry Operator

**Chart:** `open-telemetry/opentelemetry-operator`
**Namespace:** `opentelemetry-operator-system`

The Operator is a Kubernetes controller that watches for pods with OTel injection
annotations. When it sees one, it mutates the pod spec before it starts:

1. Adds an **init container** that downloads the language-specific SDK
2. Injects **environment variables** (`NODE_OPTIONS`, `OTEL_EXPORTER_OTLP_ENDPOINT`, etc.)
3. Reads the **Instrumentation CR** in the same namespace for the full SDK config

It uses a **mutating admission webhook** — the Kubernetes API server calls it for
every new pod creation before the pod is scheduled.

```
kubectl create pod
    │
    ▼
Kubernetes API Server
    │  calls mutating webhook
    ▼
OTel Operator webhook
    │  reads Instrumentation CR
    │  patches pod spec
    ▼
Pod starts with SDK pre-loaded
```

**Cert configuration:** No cert-manager in this cluster. The Operator generates its
own self-signed webhook certificate via `autoGenerateCert`.

---

### Tempo

**Chart:** `grafana/tempo v1.14.0`
**Namespace:** `monitoring`
**Storage:** 20 GiB gp3 EBS (encrypted)
**Retention:** 24 hours

Tempo receives OTLP spans from the Collector and stores them. It is queried by
Grafana via its HTTP API on port 3100. It is intentionally minimal — it stores and
retrieves traces, nothing more.

A `ServiceMonitor` is enabled so Prometheus scrapes Tempo's own operational metrics.

---

### Grafana

**Chart:** `kube-prometheus-stack` (bundled Grafana)
**Namespace:** `monitoring`

The Tempo datasource is pre-configured:

```yaml
additionalDataSources:
  - name: Tempo
    type: tempo
    url: http://tempo.monitoring.svc.cluster.local:3100
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki    # jump from a trace span → correlated logs in Loki
      lokiSearch:
        datasourceUid: loki
```

The `tracesToLogsV2` integration means that when you open a trace in Tempo, you
can click directly to the logs produced during the same time window by the same service.

---

## Pipeline Internals

### Why the order of processors matters

```
[receiver] → memory_limiter → batch → [exporter]
```

`memory_limiter` must come **before** `batch`. If it came after, the batch processor
would already have accumulated data in memory before the limiter could act — by the
time it checks, it is too late to drop data cleanly.

### Protocol translation (Stack 1: Zipkin → OTLP)

```
fake-service produces:
  Zipkin span {
    traceId: "abc123",
    name: "GET /",
    timestamp: 1710000000000000,   ← microseconds since epoch
    duration: 62,                  ← microseconds
    tags: { "http.status_code": "200" }
  }

Collector zipkin receiver converts to:
  OTLP span {
    trace_id: bytes("abc123"),
    name: "GET /",
    start_time_unix_nano: 1710000000000000000,
    end_time_unix_nano:   1710000000062000000,
    attributes: [{ key: "http.status_code", value: "200" }],
    resource: { attributes: [{ key: "service.name", value: "otel-test-app" }] }
  }
```

### Auto-instrumentation (Stack 2: SDK injection)

```
NODE_OPTIONS=--require @opentelemetry/auto-instrumentations-node/register

The SDK monkey-patches Node.js core modules at startup:
  http.createServer  → wraps every request in a span
  dns                → traces DNS lookups
  net                → traces TCP connections

Each span is exported via OTLP/HTTP to the Collector, which
forwards to Tempo — no Zipkin conversion needed.
```

---

## Port Reference

| Service          | Port | Protocol      | Purpose                               |
|------------------|------|---------------|---------------------------------------|
| OTel Collector   | 4317 | gRPC (OTLP)   | Receive from node-ws and OTLP apps    |
| OTel Collector   | 4318 | HTTP (OTLP)   | Receive from node-ws (Operator stack) |
| OTel Collector   | 9411 | HTTP (Zipkin) | Receive from fake-service             |
| Tempo            | 4317 | gRPC (OTLP)   | Receive spans from Collector          |
| Tempo            | 3100 | HTTP          | Query API used by Grafana             |
| Prometheus       | 9090 | HTTP          | Receive metrics via remote write      |
| Loki             | 3100 | HTTP          | Receive logs from Collector           |
| fake-service     | 9090 | HTTP          | Application endpoints                 |
| ALB (fake-svc)   | 80   | HTTP          | Public entry point for fake-service   |

---

## How to Test

### Stack 1 — fake-service

```bash
# Get the ALB hostname
kubectl get ingress otel-test-app -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Generate traces
ALB=<hostname-from-above>
for i in $(seq 1 20); do curl -s http://$ALB/ > /dev/null; done

# View in Grafana: Explore → Tempo → Service Name: otel-test-app
```

### Stack 2 — node-ws

```bash
# Verify injection happened
kubectl describe pod -n default -l app.kubernetes.io/name=node-ws \
  | grep -A5 'Init Containers'

# Send a request (ClusterIP only — use port-forward)
kubectl port-forward -n default svc/node-ws-node-ws 8080:80
curl http://localhost:8080/

# View in Grafana: Explore → Tempo → Service Name: node-ws
```

### Verify the shared pipeline is healthy

```bash
# Collector received and forwarded spans
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=30

# Tempo ingested them
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo --tail=20

# Operator is running and webhook is registered
kubectl get pods -n opentelemetry-operator-system
kubectl get mutatingwebhookconfiguration | grep opentelemetry
```
