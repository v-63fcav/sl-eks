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
   - [otel-platform (shared Instrumentation CRs)](#otel-platform-shared-instrumentation-crs)
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
│                               │              ▲                     │        │
│                               │    otel-platform-chart             │        │
│                               │    Instrumentation CR "nodejs"     │        │
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
    │  HTTP :80 (ALB)
    ▼
┌─────────────────────────────────────────────────────┐
│  node-ws  (node:20-alpine)                          │
│  namespace: default                                 │
│                                                     │
│  annotation:                                        │
│    instrumentation.opentelemetry.io/inject-nodejs:  │
│    "nodejs"   ← references the shared CR by name   │
│                                                     │
│  env: OTEL_SERVICE_NAME=node-ws  ← set per-app     │
│                                                     │
│  At pod startup, the Operator webhook:              │
│    1. Sees the annotation on the pod                │
│    2. Reads the "nodejs" Instrumentation CR         │
│       (deployed by otel-platform-chart)             │
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

### Why the Operator approach?

| | Collector stack | Operator stack |
|---|---|---|
| Code changes needed | None | None |
| Works with any language | No (app must speak Zipkin/OTLP) | Yes (language-specific SDK injection) |
| Trace granularity | App-level | Function/library-level (http, db, dns) |
| SDK maintenance | App's responsibility | Operator manages SDK version |
| Best for | Pre-built images with tracing built in | Standard language runtimes |

---

## Shared Backend

Both stacks send all traces through the same Collector, into the same Tempo instance,
and are visible in the same Grafana workspace — filtered by `service.name`.

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
**Chart:** `apps/app-chart/` (local Helm chart, app-agnostic)

The application is a minimal inline Node.js HTTP server. It has no OTel SDK in its
source — the Operator injects the SDK at pod startup via `NODE_OPTIONS`. The app
identifies itself in Tempo via a pod-level env var, not the shared Instrumentation CR.

#### Key values

| Value | Default | Purpose |
|---|---|---|
| `otel.serviceName` | `node-ws` | Sets `OTEL_SERVICE_NAME` on the pod — appears as service name in Tempo |
| `otel.instrumentationRef` | `nodejs` | Name of the `Instrumentation` CR to use from `otel-platform-chart` |
| `otel.inject` | `true` | Toggles the inject annotation on/off |

#### Key resources

| Resource | Name | Purpose |
|---|---|---|
| Deployment annotation | `inject-nodejs: "nodejs"` | Triggers the Operator webhook |
| Pod env var | `OTEL_SERVICE_NAME=node-ws` | App-specific service name in Tempo |
| Init container (injected) | `opentelemetry-auto-instrumentation-nodejs` | Copies SDK files into the pod |

#### Verify injection worked

```bash
kubectl describe pod -n default -l app.kubernetes.io/name=node-ws \
  | grep -A5 'Init Containers'
# Should show: opentelemetry-auto-instrumentation-nodejs

kubectl exec -n default deploy/node-ws -- env | grep NODE_OPTIONS
# Should show: --require @opentelemetry/auto-instrumentations-node/register
```

---

### OpenTelemetry Collector

**Image:** `otel/opentelemetry-collector-contrib`
**Chart:** `open-telemetry/opentelemetry-collector v0.118.0`
**Namespace:** `monitoring`
**Mode:** `deployment` (gateway — one centralised instance)

The `-contrib` image includes community-contributed components: the `zipkin` receiver
and the `loki` exporter, which are not in the core distribution.

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
  limit_percentage: 75
  spike_limit_percentage: 20
```
Prevents the Collector pod from OOM-killing itself under traffic spikes.

**`batch`** (runs second)
```yaml
batch:
  timeout: 5s
  send_batch_size: 1000
```
Reduces network overhead — 1 request per 1000 spans instead of 1000 individual requests.

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

Kubernetes controller that watches for pods with OTel injection annotations. When it
sees one, it mutates the pod spec before it starts:

1. Adds an **init container** that downloads the language-specific SDK
2. Injects **environment variables** (`NODE_OPTIONS`, `OTEL_EXPORTER_OTLP_ENDPOINT`, etc.) from the referenced `Instrumentation` CR
3. The pod-level `OTEL_SERVICE_NAME` env var takes precedence over anything set in the CR

```
kubectl create pod
    │
    ▼
Kubernetes API Server
    │  calls mutating webhook
    ▼
OTel Operator webhook
    │  reads Instrumentation CR "nodejs" from otel-platform-chart
    │  patches pod spec
    ▼
Pod starts with SDK pre-loaded
```

**Cert configuration:** No cert-manager in this cluster. The operator generates its
own self-signed webhook certificate via `autoGenerateCert`.

**Timing:** The operator registers its CRDs and webhook asynchronously after the
Helm release completes. A 30-second `time_sleep` in Terraform ensures the CRD is
available before `otel-platform-chart` tries to create an `Instrumentation` CR against it.

---

### otel-platform (shared Instrumentation CRs)

**Chart:** `apps/otel-platform-chart/` (local Helm chart)
**Namespace:** `default`
**Values:** [otel-platform-chart/values.yaml](otel-platform-chart/values.yaml)

Owns all `Instrumentation` CRs for the `default` namespace. Decoupled from individual
app charts so that:

- Adding a new app requires no changes to the platform layer
- All apps share the same collector endpoint and sampling config
- The platform team controls SDK versions and sampling independently of app teams

#### Current CRs

| CR name | Language | Annotation to use |
|---|---|---|
| `nodejs` | Node.js | `inject-nodejs: "nodejs"` |

#### Design decision: no `OTEL_SERVICE_NAME` in the CR

`OTEL_SERVICE_NAME` is intentionally omitted from the shared CR. Each app sets it
as a pod env var, which takes precedence over anything the Operator would inject.
This means one CR serves all Node.js apps in the namespace without modification.

```yaml
# otel-platform-chart — shared, no service name
spec:
  nodejs:
    env:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: http://opentelemetry-collector.monitoring:4318
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: http/protobuf
      # OTEL_SERVICE_NAME deliberately absent

# app-chart — per-app pod env var
env:
  - name: OTEL_SERVICE_NAME
    value: node-ws      # each app sets its own
```

---

### Tempo

**Chart:** `grafana/tempo v1.14.0`
**Namespace:** `monitoring`
**Storage:** 20 GiB gp3 EBS (encrypted)
**Retention:** 24 hours

Receives OTLP spans from the Collector and stores them. Queried by Grafana via HTTP
on port 3100. A `ServiceMonitor` is enabled so Prometheus scrapes Tempo's own metrics.

---

### Grafana

**Chart:** `kube-prometheus-stack` (bundled Grafana)
**Namespace:** `monitoring`

Tempo datasource pre-configured with trace-to-log correlation:

```yaml
additionalDataSources:
  - name: Tempo
    type: tempo
    url: http://tempo.monitoring.svc.cluster.local:3100
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki    # click a span → jump to matching Loki logs
      lokiSearch:
        datasourceUid: loki
```

---

## Pipeline Internals

### Why the order of processors matters

```
[receiver] → memory_limiter → batch → [exporter]
```

`memory_limiter` must come **before** `batch`. If it came after, the batch processor
would already have accumulated data in memory before the limiter could act.

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

Each span is exported via OTLP/HTTP to the Collector.
OTEL_SERVICE_NAME comes from the pod env var (set by app-chart values),
not from the shared Instrumentation CR.
```

### Deployment ordering (Terraform)

```
otel_operator
    │
    ▼ (time_sleep 30s — wait for CRD + webhook registration)
otel_platform  ← creates Instrumentation CR "nodejs"
    │
    ▼
node_ws        ← pods scheduled, webhook fires, CR found, SDK injected ✓
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
| ALB (node-ws)    | 80   | HTTP          | Public entry point for node-ws        |

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
# Get the ALB hostname
kubectl get ingress node-ws -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Generate traces
ALB=<hostname-from-above>
for i in $(seq 1 20); do curl -s http://$ALB/ > /dev/null; done

# View in Grafana: Explore → Tempo → Service Name: node-ws
```

### Verify injection worked (Stack 2)

```bash
# Init container should be present
kubectl describe pod -n default -l app.kubernetes.io/name=node-ws \
  | grep -A5 'Init Containers'

# SDK env var should be set
kubectl exec -n default deploy/node-ws -- env | grep NODE_OPTIONS

# Shared CR should exist in the namespace
kubectl get instrumentation -n default
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
