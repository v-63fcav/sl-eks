# ps-sl — Camada de Aplicações

Este diretório contém a configuração Terraform que instala todos os workloads Kubernetes no cluster EKS produzido pela camada `infra/`. Tudo é implantado via Helm releases ou recursos nativos do Kubernetes. O stack forma uma plataforma completa de observabilidade (métricas, logs, traces) mais aplicações de exemplo instrumentadas.

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

Para o diagrama completo do fluxo de dados de tracing, consulte [README-otel.md](README-otel.md).

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
| Chart | local `./otel-platform-chart` |
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
| Chart | local `./app-chart` |
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
| Chart | local `./otel-test-app-chart` |
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
| `kubernetes_storage_class_v1.gp3` | [k8s-resources.tf](k8s-resources.tf) | StorageClass EBS gp3 (criptografada, `Retain`, `WaitForFirstConsumer`) usada por todos os PVCs |

Todos os Helm releases que criam PVCs dependem desta StorageClass estar presente primeiro.

---

## Deploy

```bash
# Primeiro, a partir do diretório infra/
cd infra && terraform apply

# Em seguida, implante os apps
cd ../apps
terraform init   # necessário após adicionar o provider time
terraform apply
```

Após o `terraform apply`:
1. `kubectl get ingress -n default` — obtenha as URLs dos ALBs de node-ws e otel-test-app
2. `kubectl get ingress -n monitoring` — obtenha a URL do ALB do Grafana
3. Faça login no Grafana (`admin / changeme`) e verifique se os três datasources (Prometheus, Loki, Tempo) estão verdes
4. Verifique os targets do Prometheus: Grafana → Explore → Prometheus → `up` — todos os targets devem ser `1`
5. Envie requisições para os ALBs das aplicações para gerar traces, depois pesquise em Grafana → Explore → Tempo
