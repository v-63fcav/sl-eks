# apps

Terceira camada do cluster. Instala todos os workloads Kubernetes no cluster EKS produzido pelas camadas `infra-cluster/` e `infra-resources/`. Tudo é implantado via Helm releases ou recursos nativos do Kubernetes. O stack forma uma plataforma completa de observabilidade (métricas, logs, traces) mais aplicações de exemplo instrumentadas com OpenTelemetry.

## Visão Geral da Arquitetura

```
              ┌──────────────────────────────────────────┐
              │                 Grafana                   │  ← interface única para todos os sinais
              └───────────┬──────────────────────────────┘
                          │
           ┌──────────────┼──────────────┐
           ▼              ▼              ▼
      Prometheus         Loki          Tempo
      (métricas)         (logs)       (traces)
           ▲           ▲   ▲             ▲
           │    Promtail   │             │
           │    (DaemonSet)│             │
           └───────────────┴─────────────┘
                           ▲
                    OTel Collector
               (OTLP gRPC/HTTP + Zipkin)
                    ▲             ▲
           ┌────────┘             └────────┐
           │                              │
    otel-test-app                     node-ws
  (Zipkin, fake-service)     (OTLP, OTel Operator SDK)
```

O tráfego da internet chega nas aplicações e no Grafana através do **AWS Load Balancer Controller**, que provisiona ALBs a partir de recursos `Ingress`.

Para o diagrama completo do fluxo de dados de tracing, consulte [Stack de Observabilidade OpenTelemetry](#stack-de-observabilidade-opentelemetry).

---

## Serviços

### AWS Load Balancer Controller

| | |
|---|---|
| Chart | `aws/aws-load-balancer-controller` |
| Namespace | `kube-system` |
| Values | [values/values-alb-controller.yaml](values/values-alb-controller.yaml) |

Observa recursos `Ingress` com `ingressClassName: alb` e provisiona AWS Application Load Balancers automaticamente. Usa IRSA (IAM Roles for Service Accounts) para que nenhuma credencial estática seja necessária — o ARN da role IRSA é injetado no momento do deploy a partir dos outputs de `infra/`.

**Como usar:** anote qualquer `Ingress` com `ingressClassName: alb`. O controller cria e gerencia o ciclo de vida do ALB.

---

### kube-prometheus-stack

| | |
|---|---|
| Chart | `prometheus-community/kube-prometheus-stack` v69.3.1 |
| Namespace | `monitoring` |
| Values | [values/values-kube-prometheus-stack.yaml](values/values-kube-prometheus-stack.yaml) |

Chart guarda-chuva que instala:

- **Prometheus** — coleta métricas de todos os recursos `ServiceMonitor` e `PodMonitor` no cluster. Retenção: 15 dias / 40 GiB. Storage: 50 GiB gp3.
- **Grafana** — pré-carregado com dashboards EKS, datasource Loki e datasource Tempo (com correlação trace→log). Exposto via ALB voltado para internet na porta 80. Credenciais padrão: `admin / changeme`.
- **Alertmanager** — recebe alertas disparados pelo Prometheus. Storage: 10 GiB gp3.
- **Prometheus Operator** — observa CRDs `ServiceMonitor`/`PodMonitor` e configura os targets de scrape do Prometheus dinamicamente.
- **Node Exporter** — DaemonSet; expõe métricas de nível de host (CPU, memória, disco, rede) de cada node.
- **kube-state-metrics** — expõe métricas de estado de objetos Kubernetes (reinicializações de pod, réplicas de deployment, etc.).

**Como usar:**
1. Obtenha o hostname do ALB do Grafana: `kubectl get ingress -n monitoring`
2. Abra no navegador e faça login com `admin / changeme`.
3. Para adicionar um target de scrape para seu próprio serviço, crie um `ServiceMonitor` em qualquer namespace — o Prometheus os descobre em todo lugar (`serviceMonitorSelectorNilUsesHelmValues: false`).

---

### Loki

| | |
|---|---|
| Chart | `grafana/loki` v6.29.0 |
| Namespace | `monitoring` |
| Values | [values/values-loki.yaml](values/values-loki.yaml) |

Backend de agregação de logs. Implantado no modo **SingleBinary** (todos os componentes em um pod), adequado para dev/staging. Storage: 20 GiB gp3. Schema: TSDB v13.

O Loki é um backend passivo — ele apenas armazena logs que são enviados para ele. A coleta de logs é feita pelo **Promtail**.

**Como usar:**
1. Abra Grafana → Explore → selecione o datasource **Loki**.
2. Filtre por namespace: `{namespace="default"}`
3. Filtre por pod: `{pod=~"node-ws.*"}` ou `{pod=~"otel-test-app.*"}`
4. Combine com busca por texto: `{namespace="monitoring"} |= "error"`

> Para produção, mude `deploymentMode` para `SimpleScalable` ou `Distributed` e use S3 como armazenamento de objetos.

---

### Promtail

| | |
|---|---|
| Chart | `grafana/promtail` (latest) |
| Namespace | `monitoring` |
| Values | definidos via `set` inline em [helm.tf](helm.tf) |

DaemonSet que roda em cada node e monitora todos os logs de contêiner em `/var/log/pods/`. Anexa automaticamente labels de metadados Kubernetes (`namespace`, `pod`, `container`, `node`, `app`) como labels de stream do Loki, tornando os logs de cada pod consultáveis no Grafana sem nenhuma configuração por aplicação.

Logs são enviados para: `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`

**Como usar:** nenhuma configuração necessária por aplicação — todo stdout/stderr de todos os namespaces é coletado automaticamente assim que o Promtail está rodando.

---

### Tempo

| | |
|---|---|
| Chart | `grafana/tempo` v1.14.0 |
| Namespace | `monitoring` |
| Values | [values/values-tempo.yaml](values/values-tempo.yaml) |

Backend de tracing distribuído. Recebe traces via **OTLP gRPC (:4317)** e **OTLP HTTP (:4318)**. Retenção: 24 horas. Storage: 20 GiB gp3.

As aplicações **não** enviam traces diretamente para o Tempo — elas enviam para o **OTel Collector**, que repassa para o Tempo. Isso desacopla as aplicações do backend.

O datasource Tempo no Grafana é pré-configurado com **correlação trace→log**: clicar em um span pula automaticamente para os logs Loki correspondentes daquele pod e janela de tempo.

**Como usar:**
1. Abra Grafana → Explore → selecione o datasource **Tempo**.
2. Busque por nome de serviço, trace ID ou use a aba **Search** para filtrar por duração, status ou tags.
3. Clique em qualquer span para inspecionar atributos e saltar para os logs Loki correlacionados.

---

### OpenTelemetry Collector

| | |
|---|---|
| Chart | `open-telemetry/opentelemetry-collector` v0.118.0 |
| Namespace | `monitoring` |
| Imagem | `otel/opentelemetry-collector-contrib` |
| Values | [values/values-otel-collector.yaml](values/values-otel-collector.yaml) |

`Deployment` no modo gateway que atua como o hub central de telemetria. Aceita OTLP e Zipkin das aplicações e distribui para os três backends:

| Sinal | Receivers | Exporter | Backend |
|---|---|---|---|
| Traces | OTLP gRPC/HTTP, Zipkin | `otlp/tempo` | Tempo `:4317` |
| Métricas | OTLP gRPC/HTTP | `prometheusremotewrite` | Prometheus `:9090` |
| Logs | OTLP gRPC/HTTP | `loki` | Loki `:3100` |

Processadores em cada pipeline: `memory_limiter` (limite 75%, cap de spike 20%) → `batch` (timeout 5s, 1000 itens).

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

Operator Kubernetes que habilita **auto-instrumentação zero-code** via webhook de admissão mutante. Quando um pod é criado com uma anotação de injeção, o operator faz o patch na spec para adicionar um init container que baixa o OTel SDK específico da linguagem e define `NODE_OPTIONS` (ou equivalente) para que o SDK carregue automaticamente em runtime.

Linguagens suportadas: Node.js, Java, Python, Go, .NET.

Não requer cert-manager — o operator gera seu próprio certificado de webhook autoassinado via `autoGenerateCert`.

**Como instrumentar uma aplicação:**
1. Garanta que um `Instrumentation` CR correspondente exista no mesmo namespace (veja otel-platform abaixo).
2. Adicione a anotação no pod:
   ```yaml
   instrumentation.opentelemetry.io/inject-nodejs: "nodejs"
   ```
3. Defina `OTEL_SERVICE_NAME` como variável de ambiente no pod — isso é específico da aplicação e não faz parte do CR compartilhado.

---

### otel-platform

| | |
|---|---|
| Chart | local `./charts/otel-platform-chart` |
| Namespace | `default` |
| Values | [otel-platform-chart/values.yaml](otel-platform-chart/values.yaml) |

Implanta `Instrumentation` CRs compartilhados por todas as aplicações no namespace `default`. Desacoplado dos charts individuais das aplicações para que adicionar uma nova app não exija mudanças na camada de plataforma.

| Nome do CR | Linguagem | Referenciado por |
|---|---|---|
| `nodejs` | Node.js | anotação `inject-nodejs: "nodejs"` |

`OTEL_SERVICE_NAME` **não** é definido no CR — cada aplicação o define como variável de ambiente no pod, dando a cada serviço um nome distinto no Tempo sem precisar de um CR separado por app.

---

### node-ws

| | |
|---|---|
| Chart | local `./charts/app-chart` |
| Namespace | `default` |
| Values | [app-chart/values.yaml](app-chart/values.yaml) |

Servidor web Node.js mínimo (`node:20-alpine`) auto-instrumentado pelo OTel Operator. Exposto via ALB voltado para internet.

- 1 réplica, HTTP na porta 3000
- Resource requests: 100m CPU / 128Mi memória; limits: 500m CPU / 256Mi memória
- Traces visíveis em Grafana → Tempo → `service.name = node-ws`

O `app-chart` é agnóstico à aplicação — o nome da app, nome do serviço e imagem são todos configurados via `values.yaml`. Para implantar uma segunda app Node.js, copie o bloco `helm_release` em [helm.tf](helm.tf) e sobrescreva `nameOverride` e `otel.serviceName`.

---

### otel-test-app

| | |
|---|---|
| Chart | local `./charts/otel-test-app-chart` |
| Namespace | `default` |
| Values | [otel-test-app-chart/values.yaml](otel-test-app-chart/values.yaml) |

Serviço HTTP Go pré-construído (`nicholasjackson/fake-service:v0.26.2`) usado para gerar traces realistas sem escrever código de aplicação. Possui tracing Zipkin embutido — os spans são enviados ao OTel Collector na porta `:9411`, que os converte para OTLP e repassa ao Tempo.

- Exposto via ALB voltado para internet na porta 80
- Traces visíveis em Grafana → Tempo → `service.name = otel-test-app`
- Endpoints: `/` (gera um trace), `/health` (health check do ALB)

---

## Dependências de Infraestrutura

| Recurso | Arquivo | Finalidade |
|---|---|---|
| `kubernetes_manifest.gp3_storage_class` | [../infra-resources/storage.tf](../infra-resources/storage.tf) | StorageClass EBS gp3 (criptografada, `Retain`, `WaitForFirstConsumer`) usada por todos os PVCs |

Todos os Helm releases que criam PVCs dependem desta StorageClass estar presente. Como ela é provisionada na camada `infra-resources/`, que executa antes de `apps/`, a dependência é satisfeita pela ordem do pipeline.

---

## Deploy

```bash
# 1. Infraestrutura base — VPC + EKS
cd infra-cluster && terraform apply

# 2. Recursos do cluster — node group + addons + StorageClass
cd ../infra-resources
terraform apply \
  -var="cluster_name=<cluster_name>" \
  -var="kube_host=<cluster_endpoint>" \
  -var="kube_ca=<cluster_ca>"

# 3. Aplicações — Helm releases
cd ../apps
terraform init
terraform apply \
  -var="cluster_name=<cluster_name>" \
  -var="kube_host=<cluster_endpoint>" \
  -var="kube_ca=<cluster_ca>" \
  -var="alb_irsa_role=<alb_irsa_role>" \
  -var="vpc_id=<vpc_id>"
```

Após o `terraform apply`:
1. `kubectl get ingress -n default` — obtenha as URLs dos ALBs de node-ws e otel-test-app
2. `kubectl get ingress -n monitoring` — obtenha a URL do ALB do Grafana
3. Faça login no Grafana (`admin / changeme`) e verifique se os três datasources (Prometheus, Loki, Tempo) estão verdes
4. Verifique os targets do Prometheus: Grafana → Explore → Prometheus → `up` — todos os targets devem ser `1`
5. Envie requisições para os ALBs das aplicações para gerar traces, depois pesquise em Grafana → Explore → Tempo

---

## Stack de Observabilidade OpenTelemetry

Este documento descreve a configuração de tracing distribuído implantada neste cluster EKS.
Dois métodos complementares de instrumentação são usados, ambos roteando pelo mesmo
OTel Collector e chegando ao Grafana Tempo.

---

### Índice

1. [Visão Geral](#visão-geral)
2. [Stack 1 — OTel Collector (Tradução de Protocolo)](#stack-1--otel-collector-tradução-de-protocolo)
3. [Stack 2 — OTel Operator (Auto-Instrumentação)](#stack-2--otel-operator-auto-instrumentação)
4. [Backend Compartilhado](#backend-compartilhado)
5. [Detalhamento dos Componentes](#detalhamento-dos-componentes)
   - [fake-service (otel-test-app)](#fake-service-otel-test-app)
   - [node-ws (app-chart)](#node-ws-app-chart)
   - [OpenTelemetry Collector](#opentelemetry-collector-1)
   - [OpenTelemetry Operator](#opentelemetry-operator-1)
   - [otel-platform (Instrumentation CRs compartilhados)](#otel-platform-instrumentation-crs-compartilhados)
   - [Tempo](#tempo-1)
   - [Grafana](#grafana-1)
6. [Internos do Pipeline](#internos-do-pipeline)
7. [Referência de Portas](#referência-de-portas)
8. [Como Testar](#como-testar)

---

### Visão Geral

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Cluster EKS                                    │
│                                                                             │
│  STACK 1: Collector                     STACK 2: Operator                   │
│                                                                             │
│  ┌──────────────┐  Zipkin               ┌──────────────┐  OTLP/HTTP         │
│  │  fake-service│─────────────┐         │   node-ws    │──────────┐         │
│  │ (otel-test-  │  :9411      │         │  (app-chart) │  :4318   │         │
│  │    app)      │             │         │[SDK injetado │          │         │
│  └──────────────┘             │         │pelo Operator]│          │         │
│                               │         └──────────────┘          │         │
│                               │              ▲                    │         │
│                               │    otel-platform-chart            │         │
│                               │    Instrumentation CR "nodejs"    │         │
│                               ▼                                   ▼         │
│                    ┌──────────────────────────────────────────────────┐     │
│                    │           OpenTelemetry Collector                │     │
│                    │           (gateway, namespace: monitoring)       │     │
│                    │  receivers: zipkin :9411, otlp :4317/:4318       │     │
│                    └─────────────────────┬────────────────────────────┘     │
│                                          │  OTLP/gRPC :4317                 │
│                                          ▼                                  │
│                                   ┌──────────┐                              │
│                                   │  Tempo   │                              │
│                                   └────┬─────┘                              │
│                                        │  HTTP :3100                        │
│                                        ▼                                    │
│                                   ┌──────────┐                              │
│                                   │ Grafana  │                              │
│                                   └──────────┘                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

Os dois stacks convergem no Collector. Traces de qualquer app são armazenados no Tempo
e visíveis no Grafana pelo respectivo `service.name`.

---

### Stack 1 — OTel Collector (Tradução de Protocolo)

**App:** `otel-test-app` (fake-service)
**Como instrumentada:** Embutido — a imagem já vem com tracing Zipkin habilitado via variável de ambiente.
**Protocolo de tracing:** Zipkin HTTP → OTel Collector → OTLP → Tempo

```
Usuário / curl
    │  HTTP :80 (ALB)
    ▼
┌─────────────────────────────────────────────────────┐
│  fake-service (nicholasjackson/fake-service:v0.26.2)│
│  namespace: default                                 │
│                                                     │
│  env: NAME=otel-test-app                            │
│  env: TRACING_ZIPKIN=http://opentelemetry-          │
│       collector.monitoring:9411/api/v2/spans        │
│                                                     │
│  A cada requisição:                                 │
│    1. Processa a requisição HTTP                    │
│    2. Registra tempo e status                       │
│    3. Constrói um span Zipkin                       │
│    4. Faz POST do span para TRACING_ZIPKIN          │
└────────────────────────┬────────────────────────────┘
                         │  POST /api/v2/spans (Zipkin, :9411)
                         ▼
              OTel Collector (zipkin receiver)
                         │  converte Zipkin → OTLP
                         ▼
                       Tempo
```

**Por que Zipkin e não OTLP?**
O fake-service é anterior ao padrão OTLP. Seu suporte a tracing é baseado na biblioteca
cliente Zipkin. Como o Collector aceita ambos os protocolos, isso não é um problema —
ele traduz de forma transparente e o Tempo nunca vê Zipkin.

---

### Stack 2 — OTel Operator (Auto-Instrumentação)

**App:** `node-ws` (app-chart)
**Como instrumentada:** Zero-code — o OTel Operator injeta o SDK Node.js na inicialização do pod via webhook mutante.
**Protocolo de tracing:** OTLP/HTTP → OTel Collector → OTLP/gRPC → Tempo

```
Usuário / curl
    │  HTTP :80 (ALB)
    ▼
┌─────────────────────────────────────────────────────┐
│  node-ws  (node:20-alpine)                          │
│  namespace: default                                 │
│                                                     │
│  anotação:                                          │
│    instrumentation.opentelemetry.io/inject-nodejs:  │
│    "nodejs"   ← referencia o CR compartilhado       │
│                                                     │
│  env: OTEL_SERVICE_NAME=node-ws  ← definido por app │
│                                                     │
│  Na inicialização do pod, o webhook do Operator:    │
│    1. Vê a anotação no pod                          │
│    2. Lê o Instrumentation CR "nodejs"              │
│       (implantado pelo otel-platform-chart)         │
│    3. Injeta um init container que baixa            │
│       o OTel SDK do Node.js                         │
│    4. Add NODE_OPTIONS=--require @opentelemetry/..  │
│       para que o SDK instrumente http, dns, etc.    │
│                                                     │
│  Em runtime, o SDK:                                 │
│    1. Intercepta toda requisição http.createServer  │
│    2. Cria um span com method, url, status          │
│    3. Exporta via OTLP HTTP para o Collector        │
└────────────────────────┬────────────────────────────┘
                         │  OTLP/HTTP :4318
                         ▼
              OTel Collector (otlp/http receiver)
                         │  repassa como OTLP/gRPC
                         ▼
                       Tempo
```

#### Por que usar o Operator?

| | Stack Collector | Stack Operator |
|---|---|---|
| Mudanças de código necessárias | Nenhuma | Nenhuma |
| Funciona com qualquer linguagem | Não (app deve falar Zipkin/OTLP) | Sim (injeção de SDK específico da linguagem) |
| Granularidade de traces | Nível de aplicação | Nível de função/biblioteca (http, db, dns) |
| Manutenção do SDK | Responsabilidade da app | Operator gerencia a versão do SDK |
| Melhor para | Imagens pré-construídas com tracing embutido | Runtimes de linguagem padrão |

---

### Backend Compartilhado

Ambos os stacks enviam todos os traces pelo mesmo Collector, para a mesma instância do Tempo,
e são visíveis no mesmo workspace do Grafana — filtrados por `service.name`.

```
Grafana → Explore → Tempo → Search
  Service Name: otel-test-app   ← traces do Stack 1
  Service Name: node-ws         ← traces do Stack 2
```

---

### Detalhamento dos Componentes

#### fake-service (otel-test-app)

**Imagem:** `nicholasjackson/fake-service:v0.26.2`
**Namespace:** `default`
**Chart:** `apps/charts/otel-test-app-chart/` (chart Helm local)

##### Variáveis de ambiente principais

| Variável | Valor | Finalidade |
|---|---|---|
| `NAME` | `otel-test-app` | Define o nome do serviço reportado nos traces |
| `TRACING_ZIPKIN` | `http://opentelemetry-collector.monitoring:9411/api/v2/spans` | Onde fazer POST dos spans no formato Zipkin |

##### Endpoints

| Caminho | Descrição |
|---|---|
| `/` | Retorna uma resposta JSON; gera um span de trace |
| `/health` | Health check; usado pelo ALB e probes |

---

#### node-ws (app-chart)

**Imagem:** `node:20-alpine`
**Namespace:** `default`
**Chart:** `apps/charts/app-chart/` (chart Helm local, agnóstico à aplicação)

A aplicação é um servidor HTTP Node.js mínimo inline. Não possui OTel SDK em seu
código-fonte — o Operator injeta o SDK na inicialização do pod via `NODE_OPTIONS`. A app
se identifica no Tempo via variável de ambiente no pod, não pelo Instrumentation CR compartilhado.

##### Values principais

| Value | Padrão | Finalidade |
|---|---|---|
| `otel.serviceName` | `node-ws` | Define `OTEL_SERVICE_NAME` no pod — aparece como nome do serviço no Tempo |
| `otel.instrumentationRef` | `nodejs` | Nome do CR `Instrumentation` a usar do `otel-platform-chart` |
| `otel.inject` | `true` | Liga/desliga a anotação de injeção |

##### Recursos principais

| Recurso | Nome | Finalidade |
|---|---|---|
| Anotação do Deployment | `inject-nodejs: "nodejs"` | Dispara o webhook do Operator |
| Variável de ambiente do pod | `OTEL_SERVICE_NAME=node-ws` | Nome de serviço específico da app no Tempo |
| Init container (injetado) | `opentelemetry-auto-instrumentation-nodejs` | Copia arquivos do SDK para dentro do pod |

##### Verificar se a injeção funcionou

```bash
kubectl describe pod -n default -l app.kubernetes.io/name=node-ws \
  | grep -A5 'Init Containers'
# Deve mostrar: opentelemetry-auto-instrumentation-nodejs

kubectl exec -n default deploy/node-ws -- env | grep NODE_OPTIONS
# Deve mostrar: --require @opentelemetry/auto-instrumentations-node/register
```

---

#### OpenTelemetry Collector

**Imagem:** `otel/opentelemetry-collector-contrib`
**Chart:** `open-telemetry/opentelemetry-collector v0.118.0`
**Namespace:** `monitoring`
**Modo:** `deployment` (gateway — uma instância centralizada)

A imagem `-contrib` inclui componentes contribuídos pela comunidade: o receiver `zipkin`
e o exporter `loki`, que não estão na distribuição principal.

##### Receivers

```yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: "0.0.0.0:4317" }   # node-ws (stack Operator) e qualquer app OTLP
      http: { endpoint: "0.0.0.0:4318" }   # node-ws (stack Operator)
  zipkin:
    endpoint: "0.0.0.0:9411"               # fake-service (stack Collector)
```

##### Processadores

**`memory_limiter`** (executa primeiro em todo pipeline)
```yaml
memory_limiter:
  check_interval: 1s
  limit_percentage: 75
  spike_limit_percentage: 20
```
Impede que o pod do Collector seja morto por OOM em picos de tráfego.

**`batch`** (executa segundo)
```yaml
batch:
  timeout: 5s
  send_batch_size: 1000
```
Reduz overhead de rede — 1 requisição por 1000 spans em vez de 1000 requisições individuais.

##### Pipelines

```
pipeline de traces:
  receivers:  [otlp, zipkin]          ← aceita ambos os stacks
  processors: [memory_limiter, batch]
  exporters:  [otlp/tempo]

pipeline de métricas:
  receivers:  [otlp]
  processors: [memory_limiter, batch]
  exporters:  [prometheusremotewrite]

pipeline de logs:
  receivers:  [otlp]
  processors: [memory_limiter, batch]
  exporters:  [loki]
```

---

#### OpenTelemetry Operator

**Chart:** `open-telemetry/opentelemetry-operator`
**Namespace:** `opentelemetry-operator-system`

Controller Kubernetes que observa pods com anotações de injeção OTel. Quando detecta um,
faz o patch na spec do pod antes de iniciá-lo:

1. Adiciona um **init container** que baixa o SDK específico da linguagem
2. Injeta **variáveis de ambiente** (`NODE_OPTIONS`, `OTEL_EXPORTER_OTLP_ENDPOINT`, etc.) do CR `Instrumentation` referenciado
3. A variável `OTEL_SERVICE_NAME` no nível do pod tem precedência sobre qualquer valor que o Operator injetaria

```
kubectl create pod
    │
    ▼
Kubernetes API Server
    │  chama webhook mutante
    ▼
OTel Operator webhook
    │  lê Instrumentation CR "nodejs" do otel-platform-chart
    │  faz patch na spec do pod
    ▼
Pod inicia com SDK pré-carregado
```

**Configuração de certificado:** Sem cert-manager neste cluster. O operator gera seu
próprio certificado de webhook autoassinado via `autoGenerateCert`.

**Temporização:** O operator registra seus CRDs e webhook de forma assíncrona após o
Helm release ser concluído. Uma espera de 30 segundos no Terraform (`time_sleep`) garante que o CRD
esteja disponível antes que o `otel-platform-chart` tente criar um CR `Instrumentation` contra ele.

---

#### otel-platform (Instrumentation CRs compartilhados)

**Chart:** `apps/charts/otel-platform-chart/` (chart Helm local)
**Namespace:** `default`
**Values:** [charts/otel-platform-chart/values.yaml](charts/otel-platform-chart/values.yaml)

Possui todos os CRs `Instrumentation` para o namespace `default`. Desacoplado dos charts
individuais das aplicações para que:

- Adicionar uma nova app não exija mudanças na camada de plataforma
- Todas as apps compartilhem o mesmo endpoint do collector e configuração de sampling
- O time de plataforma controle versões de SDK e sampling de forma independente dos times de app

##### CRs atuais

| Nome do CR | Linguagem | Anotação para usar |
|---|---|---|
| `nodejs` | Node.js | `inject-nodejs: "nodejs"` |

##### Decisão de design: sem `OTEL_SERVICE_NAME` no CR

`OTEL_SERVICE_NAME` é omitido intencionalmente do CR compartilhado. Cada app o define
como variável de ambiente no pod, que tem precedência sobre qualquer coisa que o Operator injetaria.
Isso significa que um único CR serve todas as apps Node.js no namespace sem modificação.

```yaml
# otel-platform-chart — compartilhado, sem nome de serviço
spec:
  nodejs:
    env:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: http://opentelemetry-collector.monitoring:4318
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: http/protobuf
      # OTEL_SERVICE_NAME deliberadamente ausente

# app-chart — variável de ambiente no pod por app
env:
  - name: OTEL_SERVICE_NAME
    value: node-ws      # cada app define o seu próprio
```

---

#### Tempo

**Chart:** `grafana/tempo v1.14.0`
**Namespace:** `monitoring`
**Storage:** 20 GiB gp3 EBS (criptografado)
**Retenção:** 24 horas

Recebe spans OTLP do Collector e os armazena. Consultado pelo Grafana via HTTP
na porta 3100. Um `ServiceMonitor` é habilitado para que o Prometheus colete as próprias métricas do Tempo.

---

#### Grafana

**Chart:** `kube-prometheus-stack` (Grafana integrado)
**Namespace:** `monitoring`

Datasource Tempo pré-configurado com correlação trace-to-log:

```yaml
additionalDataSources:
  - name: Tempo
    type: tempo
    url: http://tempo.monitoring.svc.cluster.local:3100
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki    # clique em um span → pula para os logs Loki correspondentes
      lokiSearch:
        datasourceUid: loki
```

---

### Internos do Pipeline

#### Por que a ordem dos processadores importa

```
[receiver] → memory_limiter → batch → [exporter]
```

O `memory_limiter` deve vir **antes** do `batch`. Se viesse depois, o processador batch
já teria acumulado dados em memória antes que o limiter pudesse agir.

#### Tradução de protocolo (Stack 1: Zipkin → OTLP)

```
fake-service produz:
  Zipkin span {
    traceId: "abc123",
    name: "GET /",
    timestamp: 1710000000000000,   ← microssegundos desde epoch
    duration: 62,                  ← microssegundos
    tags: { "http.status_code": "200" }
  }

Collector zipkin receiver converte para:
  OTLP span {
    trace_id: bytes("abc123"),
    name: "GET /",
    start_time_unix_nano: 1710000000000000000,
    end_time_unix_nano:   1710000000062000000,
    attributes: [{ key: "http.status_code", value: "200" }],
    resource: { attributes: [{ key: "service.name", value: "otel-test-app" }] }
  }
```

#### Auto-instrumentação (Stack 2: injeção de SDK)

```
NODE_OPTIONS=--require @opentelemetry/auto-instrumentations-node/register

O SDK faz monkey-patch nos módulos core do Node.js na inicialização:
  http.createServer  → envolve cada requisição em um span
  dns                → rastreia lookups DNS
  net                → rastreia conexões TCP

Cada span é exportado via OTLP/HTTP para o Collector.
OTEL_SERVICE_NAME vem da variável de ambiente no pod (definida pelos values do app-chart),
não do Instrumentation CR compartilhado.
```

#### Ordem de deploy (Terraform)

```
otel_operator
    │
    ▼ (time_sleep 30s — aguarda registro do CRD + webhook)
otel_platform  ← cria Instrumentation CR "nodejs"
    │
    ▼
node_ws        ← pods agendados, webhook dispara, CR encontrado, SDK injetado ✓
```

---

### Referência de Portas

| Serviço | Porta | Protocolo | Finalidade |
|---|---|---|---|
| OTel Collector | 4317 | gRPC (OTLP) | Receber de node-ws e apps OTLP |
| OTel Collector | 4318 | HTTP (OTLP) | Receber de node-ws (stack Operator) |
| OTel Collector | 9411 | HTTP (Zipkin) | Receber do fake-service |
| Tempo | 4317 | gRPC (OTLP) | Receber spans do Collector |
| Tempo | 3100 | HTTP | API de consulta usada pelo Grafana |
| Prometheus | 9090 | HTTP | Receber métricas via remote write |
| Loki | 3100 | HTTP | Receber logs do Collector |
| fake-service | 9090 | HTTP | Endpoints da aplicação |
| ALB (fake-svc) | 80 | HTTP | Ponto de entrada público para o fake-service |
| ALB (node-ws) | 80 | HTTP | Ponto de entrada público para o node-ws |

---

### Como Testar

#### Stack 1 — fake-service

```bash
# Obter o hostname do ALB
kubectl get ingress otel-test-app -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Gerar traces
ALB=<hostname-acima>
for i in $(seq 1 20); do curl -s http://$ALB/ > /dev/null; done

# Ver no Grafana: Explore → Tempo → Service Name: otel-test-app
```

#### Stack 2 — node-ws

```bash
# Obter o hostname do ALB
kubectl get ingress node-ws -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Gerar traces
ALB=<hostname-acima>
for i in $(seq 1 20); do curl -s http://$ALB/ > /dev/null; done

# Ver no Grafana: Explore → Tempo → Service Name: node-ws
```

#### Verificar se a injeção funcionou (Stack 2)

```bash
# Init container deve estar presente
kubectl describe pod -n default -l app.kubernetes.io/name=node-ws \
  | grep -A5 'Init Containers'

# Variável de ambiente do SDK deve estar definida
kubectl exec -n default deploy/node-ws -- env | grep NODE_OPTIONS

# CR compartilhado deve existir no namespace
kubectl get instrumentation -n default
```

#### Verificar se o pipeline compartilhado está saudável

```bash
# Collector recebeu e repassou os spans
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=30

# Tempo os ingeriu
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo --tail=20

# Operator está rodando e webhook está registrado
kubectl get pods -n opentelemetry-operator-system
kubectl get mutatingwebhookconfiguration | grep opentelemetry
```
