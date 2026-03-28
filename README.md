# ps-sl - Plataforma de Observabilidade Kubernetes

[![Terraform](https://img.shields.io/badge/Terraform-1.9+-623CE4?style=for-the-badge&logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![AWS EKS](https://img.shields.io/badge/AWS%20EKS-FF9900?style=for-the-badge&logo=amazon-aws&logoColor=white)](https://aws.amazon.com/eks/)
[![Helm](https://img.shields.io/badge/Helm-3.x-0F1689?style=for-the-badge&logo=helm&logoColor=white)](https://helm.sh/)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=for-the-badge&logo=prometheus&logoColor=white)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=for-the-badge&logo=grafana&logoColor=white)](https://grafana.com/)
[![OpenTelemetry](https://img.shields.io/badge/OpenTelemetry-425CC7?style=for-the-badge&logo=opentelemetry&logoColor=white)](https://opentelemetry.io/)
[![GitHub Actions](https://img.shields.io/badge/GitHub%20Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white)](https://github.com/features/actions)

---

## 📋 Índice

- [Visão Geral](#visão-geral)
- [Arquitetura](#arquitetura)
- [Pré-requisitos](#pré-requisitos)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Componentes de Infraestrutura](#componentes-de-infraestrutura)
- [Componentes de Aplicação](#componentes-de-aplicação)
- [Deploy](#deploy)
- [Acesso e Credenciais](#acesso-e-credenciais)
- [Configuração](#configuração)
- [Solução de Problemas](#solução-de-problemas)
- [Roadmap](#roadmap)
- [Contribuindo](#contribuindo)
- [Licença](#licença)

---

## 🎯 Visão Geral

Este projeto implementa uma plataforma completa de observabilidade Kubernetes na AWS EKS utilizando as melhores práticas de Infraestrutura como Código (IaC). A solução utiliza Terraform para gerenciamento declarativo de infraestrutura, EKS para orquestração de contêineres e o stack Prometheus/Grafana/Loki/Tempo para monitoramento e observabilidade abrangente dos três sinais (métricas, logs e traces).

### Funcionalidades Principais

- **Infraestrutura Declarativa**: Provisionamento de infraestrutura baseado em Terraform
- **Alta Disponibilidade**: Cluster EKS multi-AZ com node groups distribuídos
- **Observabilidade Completa**: Stack integrado de métricas (Prometheus), logs (Loki + Promtail) e traces (Tempo)
- **Tracing Distribuído**: Dois padrões de instrumentação — Zipkin via OTel Collector e auto-instrumentação zero-code via OTel Operator
- **CI/CD**: GitHub Actions para implantações automatizadas
- **Ingress**: AWS Application Load Balancer Controller para gerenciamento de tráfego
- **Segurança**: Topologia de rede isolada com subnets privadas para workloads

---

## 🏗️ Arquitetura

### Infraestrutura AWS

```
+-----------------------------------------------------------------------------------+
|                              AWS / Region: us-east-2                               |
|  +-----------------------------------------------------------------------------+  |
|  |                             VPC  10.0.0.0/16                                 |  |
|  |                                                                              |  |
|  |  +-------------------------+  +---------------------------+                  |  |
|  |  | Public Band (ALB/NAT)   |  | Node Band (Workers)       |                  |  |
|  |  | 10.0.8.0/24  AZ-a       |  | 10.0.0.0/24  AZ-a         |                  |  |
|  |  | 10.0.9.0/24  AZ-b       |  | 10.0.1.0/24  AZ-b         |                  |  |
|  |  |                         |  |                           |                  |  |
|  |  | IGW / NAT GW (xAZ)     |  | t3.medium x 2-6           |                  |  |
|  |  | ALB -- Grafana          |  | 1 IP/node (custom CNI)    |                  |  |
|  |  +-------------------------+  +---------------------------+                  |  |
|  |                                                                              |  |
|  |  +-----------------------------------------------------+                    |  |
|  |  |              Pod Band (Custom Networking)            |                    |  |
|  |  |              10.0.32.0/19  AZ-a  (~8k IPs)           |                    |  |
|  |  |              10.0.64.0/19  AZ-b  (~8k IPs)           |                    |  |
|  |  +-----------------------------------------------------+                    |  |
|  |                                                                              |  |
|  |  +-------------------------------------------------------------------+      |  |
|  |  |              EKS Cluster (Kubernetes 1.34)                        |      |  |
|  |  |   Managed Control Plane / OIDC / EBS CSI addon / VPC CNI addon    |      |  |
|  |  +-------------------------------------------------------------------+      |  |
|  |                                                                              |  |
|  |  VPC Endpoints: S3 (Gateway) / ECR API / ECR DKR / STS                      |  |
|  |  VPC Flow Logs -> CloudWatch Logs (30d retention)                            |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### Stack de Observabilidade

```
              +------------------------------------------+
              |                 Grafana                  |  <- ALB
              +-----------+------------------------------+
                          |
           +--------------+--------------+
           v              v              v
      Prometheus         Loki          Tempo
      (metrics)         (logs)        (traces)
           ^           ^   ^             ^
           |    Promtail   |             |
           |    (DaemonSet)|             |
           +---------------+-------------+
                           ^
                    OTel Collector
               (OTLP gRPC/HTTP + Zipkin)
                    ^             ^
           +--------+             +--------+
           |                               |
    otel-test-app                     node-ws
  (Zipkin, fake-service)     (OTLP, OTel Operator SDK)
```

> Para o detalhamento completo do pipeline de tracing (Zipkin vs OTLP, auto-instrumentação, portas), consulte [apps/README-otel.md](apps/README-otel.md).

### Fases de Deploy

A solução é implantada em duas fases distintas:

1. **Fase de Infraestrutura** (`infra/`): Infraestrutura base AWS
2. **Fase de Aplicações** (`apps/`): Aplicações Kubernetes e stack de monitoramento

---

## 📦 Pré-requisitos

Antes de implantar este projeto, certifique-se de ter o seguinte instalado:

### Ferramentas Necessárias

- **AWS CLI**: `>= 2.0`
- **Terraform**: `>= 1.0`
- **kubectl**: `>= 1.20`
- **Helm**: `>= 3.0`
- **Git**: Versão mais recente

### Requisitos AWS

- Conta AWS ativa com permissões apropriadas
- Credenciais da AWS CLI configuradas
- Quotas de serviço suficientes para:
  - Clusters EKS e node groups
  - VPC, subnets e recursos de rede
  - Load balancers

### Configuração GitHub

- Repositório GitHub com Actions habilitado
- Credenciais AWS configuradas como secrets do repositório
- Backend Terraform Cloud/Enterprise configurado

---

## 📁 Estrutura do Projeto

```
sl-eks/
+-- infra/                              # Camada de infraestrutura AWS
|   +-- eks-cluster.tf                 # Cluster EKS, node groups, addon EBS CSI
|   +-- iam.tf                         # Roles IRSA para EBS CSI e ALB controller
|   +-- iam_policy.json                # Política IAM do ALB controller
|   +-- vpc.tf                         # VPC, subnets, NAT Gateway, IGW
|   +-- sg.tf                          # Security group dos worker nodes
|   +-- outputs.tf                     # Outputs consumidos pela camada apps/
|   +-- variables.tf                   # Variáveis de entrada
|   +-- versions.tf                    # Versões dos providers
|   +-- backend.tf                     # Configuração do backend Terraform
|   +-- README.md                      # Documentação detalhada da camada infra
+-- apps/                              # Camada de aplicações Kubernetes
|   +-- helm.tf                        # Todos os Helm releases
|   +-- k8s-resources.tf               # StorageClass gp3
|   +-- providers.tf                   # Providers helm e kubernetes
|   +-- variables.tf                   # Variáveis de entrada
|   +-- versions.tf                    # Versões dos providers
|   +-- backend.tf                     # Configuração do backend Terraform
|   +-- app-chart/                     # Chart Helm genérico de aplicação (node-ws)
|   +-- otel-test-app-chart/           # Chart Helm do fake-service (otel-test-app)
|   +-- otel-platform-chart/           # Chart Helm com Instrumentation CRs compartilhados
|   +-- values/                        # Values dos charts Helm
|   |   +-- values-alb-controller.yaml
|   |   +-- values-kube-prometheus-stack.yaml
|   |   +-- values-loki.yaml
|   |   +-- values-tempo.yaml
|   |   +-- values-otel-collector.yaml
|   |   +-- values-otel-operator.yaml
|   +-- README.md                      # Documentação detalhada da camada apps
|   +-- README-otel.md                 # Detalhamento do pipeline de tracing OTel
+-- .gitignore
+-- README.md
```

> Documentação detalhada de cada recurso: [infra/README.md](infra/README.md) e [apps/README.md](apps/README.md)

---

## 🏢 Componentes de Infraestrutura

> Documentação completa em [infra/README.md](infra/README.md)

### Arquitetura de Rede

A VPC usa um design em **bandas de endereços** para separar tipos de subnet e permitir crescimento sequencial por AZ:

| Banda | Range | Prefixo/AZ | Slots disponíveis |
|---|---|---|---|
| Nodes | `10.0.0.0–10.0.7.255` | `/24` (~249 IPs) | 8 AZs |
| Public (ALB/NAT) | `10.0.8.0–10.0.15.255` | `/24` (~249 IPs) | 8 AZs |
| Pods | `10.0.32.0–10.0.255.255` | `/19` (~8k IPs) | 7 AZs |

- **Custom Networking (VPC CNI)**: pods recebem IPs da banda de pods (subnets `intra`), não da subnet dos nodes. Cada node consome apenas 1 IP da subnet de nodes (ENI primário).
- **NAT Gateway por AZ**: um NAT GW por zona de disponibilidade para eliminar ponto único de falha e cobranças de tráfego inter-AZ.
- **VPC Flow Logs**: captura todo o tráfego de rede no CloudWatch Logs com retenção de 30 dias.
- **VPC Endpoints**: S3 (Gateway, gratuito), ECR API, ECR DKR e STS — mantém pulls de imagem e tokens IRSA dentro da rede AWS sem passar pelo NAT GW.
- **Security Group** dos worker nodes: ingress liberado para RFC-1918, egress irrestrito.

> **Referência futura — Opção CGNAT:** O design atual suporta até 7 AZs de pods dentro do `/16` da VPC. Para escala além desse limite, a alternativa recomendada é adicionar um **CIDR secundário da VPC no espaço CGNAT (`100.64.0.0/10`)** dedicado às subnets de pods — desacoplando completamente o espaço de IPs de pods do `/16` principal e eliminando o teto de 7 AZs. Ver detalhes de implementação em [infra/README.md](infra/README.md).

### Recursos de Computação

- **Cluster EKS** v1.34 com endpoints público e privado habilitados
- **Node Group** gerenciado: `t3.medium` (2 vCPU, 4 GiB), 2 nodes (escala até 6), nas subnets privadas
- **Addon VPC CNI** com custom networking habilitado (`AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true`)

### Configuração IAM (IRSA)

Nenhuma credencial estática. Ambas as roles usam **IRSA via OIDC**:

- **EBS CSI Driver Role** — permite ao addon `aws-ebs-csi-driver` criar/anexar volumes EBS, restrito à service account `kube-system:ebs-csi-controller-sa`
- **ALB Controller Role** — permite ao AWS Load Balancer Controller gerenciar ALBs, restrito à service account `kube-system:aws-load-balancer-controller`
- **EKS Access Entries** — acesso admin configurado via API de Access Entries (sem necessidade de editar `aws-auth` ConfigMap)

---

## 🚀 Componentes de Aplicação

> Documentação completa em [apps/README.md](apps/README.md)

### Storage

- **StorageClass `gp3`**: provisioner in-tree (`kubernetes.io/aws-ebs`), criptografia habilitada, política `Retain`, bind `WaitForFirstConsumer`

### Stack de Observabilidade

| Componente | Função | Sinal |
|---|---|---|
| **kube-prometheus-stack** | Coleta de métricas, dashboards, alertas | Métricas |
| **Loki** | Armazenamento de logs | Logs |
| **Promtail** | Coleta de logs de todos os namespaces (DaemonSet) | Logs |
| **Tempo** | Armazenamento de traces distribuídos | Traces |
| **OTel Collector** | Gateway OTLP — recebe e roteia os três sinais | Métricas / Logs / Traces |
| **OTel Operator** | Auto-instrumentação zero-code via webhook mutante | Traces |
| **otel-platform** | Instrumentation CRs compartilhados por namespace | — |
| **AWS Load Balancer Controller** | Provisiona ALBs a partir de recursos Ingress | — |

### Aplicações de Exemplo

| Aplicação | Imagem | Instrumentação | Protocolo |
|---|---|---|---|
| **otel-test-app** | `nicholasjackson/fake-service:v0.26.2` | Built-in (Zipkin) | Zipkin → OTel Collector → Tempo |
| **node-ws** | `node:20-alpine` | Zero-code (OTel Operator SDK inject) | OTLP/HTTP → OTel Collector → Tempo |

> Para detalhes sobre os dois padrões de instrumentação, consulte [apps/README-otel.md](apps/README-otel.md).

---

## 🚦 Deploy

### Fase 1: Deploy de Infraestrutura

1. **Navegue para o diretório de infraestrutura**
   ```bash
   cd infra
   ```

2. **Inicialize o Terraform**
   ```bash
   terraform init
   ```

3. **Revise e personalize as variáveis**
   ```bash
   terraform plan
   ```

4. **Implante a infraestrutura**
   ```bash
   terraform apply
   ```

5. **Configure o kubectl**
   ```bash
   aws eks update-kubeconfig --region <região> --name $(terraform output -raw cluster_name)
   ```

### Fase 2: Deploy de Aplicações

1. **Navegue para o diretório de aplicações**
   ```bash
   cd ../apps
   ```

2. **Inicialize o Terraform**
   ```bash
   terraform init
   ```

3. **Revise o plano de deploy**
   ```bash
   terraform plan
   ```

4. **Implante o stack de monitoramento**
   ```bash
   terraform apply
   ```

### Destruição do ambiente

> ⚠️ **Ordem obrigatória**: destrua `apps/` primeiro. Os Helm releases criam recursos AWS (ALBs, ENIs, Security Groups) fora do estado do Terraform de `infra/`. Se o `infra/` for destruído primeiro, esses recursos ficam órfãos e impedem a exclusão da VPC.

```bash
# 1. Destruir aplicações (remove ALBs e demais recursos AWS criados pelos Helm releases)
cd apps
terraform destroy

# 2. Destruir infraestrutura
cd ../infra
terraform destroy
```

### GitHub Actions Deploy

O projeto utiliza GitHub Actions para CI/CD. Certifique-se de que os seguintes secrets estejam configurados no seu repositório:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `TF_API_TOKEN` (se usando Terraform Cloud/Enterprise)

O pipeline irá:
1. Validar a configuração Terraform
2. Executar verificações de segurança
3. Aplicar mudanças na infraestrutura
4. Implantar aplicações

---

## 🔐 Acesso e Credenciais

### Dashboard Grafana

```bash
# Obter a URL do ALB criado pelo Ingress do Grafana
kubectl get ingress -n monitoring
```

- **Usuário**: `admin`
- **Senha**: `changeme` (definida em `values-kube-prometheus-stack.yaml` — altere antes de ir a produção)
- Datasources pré-configurados: **Prometheus**, **Loki**, **Tempo** (com correlação trace→log)

> ⚠️ **Nota de Segurança**: Altere as credenciais padrão imediatamente após o primeiro deploy. Use AWS Secrets Manager ou secrets do Kubernetes para deployments em produção.

### Aplicações de Teste

```bash
# URL do otel-test-app (fake-service)
kubectl get ingress otel-test-app -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# URL do node-ws
kubectl get ingress node-ws -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### Recursos AWS

Acesse o Console AWS para visualizar:
- Cluster EKS: `Amazon EKS > Clusters`
- Load Balancers: `EC2 > Load Balancers`
- VPC: `VPC > Your VPCs`

---

## ⚙️ Configuração

### Variáveis Terraform

Principais variáveis para configurar:

```hcl
# Infraestrutura (infra/variables.tf)
variable "aws_region" {
  description = "Região AWS para deploy"
  default     = "us-east-2"
}

variable "vpc_cidr" {
  description = "Bloco CIDR da VPC"
  default     = "10.0.0.0/16"
}

variable "eks_admin_principal_arns" {
  type        = list(string)
  description = "Lista de ARNs IAM com acesso de administrador ao cluster EKS"
}
```

> **Nota**: O parâmetro `eks_admin_principal_arns` é obrigatório e configura automaticamente o acesso administrativo ao cluster EKS via Terraform, usando a API de Access Entries (sem necessidade de editar o `aws-auth` ConfigMap).

### Values Helm

Cada componente possui seu próprio arquivo de values em `apps/values/`. Exemplos de customizações comuns:

```yaml
# apps/values/values-kube-prometheus-stack.yaml
prometheus:
  prometheusSpec:
    retention: 15d        # Retenção de métricas
    retentionSize: "40GiB"

# apps/values/values-tempo.yaml
tempo:
  retention: 24h          # Retencao de traces (curta - aumente conforme necessario)

# apps/values/values-loki.yaml
singleBinary:
  persistence:
    size: 20Gi            # Tamanho do volume de logs
```

### Configuração de Escala

Modifique o sizing do node group em `infra/eks-cluster.tf`:

```hcl
node_group = {
  min_size     = 2
  max_size     = 6
  desired_size = 2
}
```

---

## 🛠️ Solução de Problemas

### Problemas Comuns

#### 1. Problemas de Lock do Estado Terraform

```bash
# Forçar desbloqueio se necessário
terraform force-unlock <LOCK_ID>
```

#### 2. Cluster EKS Não Respondendo

```bash
# Verificar status do cluster
aws eks describe-cluster --name <nome-do-cluster> --region <região>

# Verificar status do node group
kubectl get nodes
```

#### 3. Grafana Não Acessível

```bash
# Verificar status do load balancer
kubectl get svc -n monitoring

# Verificar logs dos pods
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana
```

#### 4. Prometheus Não Coletando Métricas

```bash
# Verificar targets do Prometheus
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Acesse http://localhost:9090/targets
```

#### 5. Traces Não Aparecendo no Grafana

```bash
# Verificar se o OTel Collector está recebendo spans
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=30

# Verificar se o OTel Operator está rodando
kubectl get pods -n opentelemetry-operator-system

# Verificar se a SDK foi injetada no pod
kubectl describe pod -n default -l app.kubernetes.io/name=node-ws \
  | grep -A5 'Init Containers'
```

### Modo de Debug

Habilite logging detalhado:

```bash
export TF_LOG=DEBUG
terraform apply
```

---

## 🗺️ Roadmap

Este roadmap mapeia o estado atual do cluster em relação ao padrão de referência para clusters EKS enterprise-grade, baseado no [AWS EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/) e nas recomendações de segurança AWS/CIS.

---

### ✅ Concluído

#### Rede
- [x] **VPC em bandas de endereços** — separação node/público/pod com slots sequenciais para expansão por AZ
- [x] **Custom Networking (VPC CNI)** — pods recebem IPs da banda de pods (`intra_subnets`); nodes consomem apenas 1 IP cada
- [x] **NAT Gateway por AZ** — elimina ponto único de falha e cobranças inter-AZ (`one_nat_gateway_per_az = true`)
- [x] **VPC Endpoints** — S3 (Gateway, gratuito), ECR API, ECR DKR, STS; pulls de imagem e tokens IRSA não passam pelo NAT GW
- [x] **VPC Flow Logs** — captura todo tráfego (`ALL`) no CloudWatch Logs com retenção de 30 dias
- [x] **ENIConfig CRDs** — mapeamento AZ → subnet de pods gerenciado automaticamente pela camada `apps/`

#### Computação e Identidade
- [x] **Cluster EKS gerenciado** com endpoints público e privado habilitados
- [x] **Node Group gerenciado** — `AL2023_x86_64_STANDARD`, escala de 2 a 6 nodes nas subnets privadas
- [x] **IRSA para todos os componentes AWS** — EBS CSI Driver e ALB Controller sem credenciais estáticas
- [x] **EKS Access Entries** — acesso admin via API moderna (sem edição manual do `aws-auth` ConfigMap)
- [x] **Addon EBS CSI Driver** — provisionamento dinâmico de volumes EBS com IRSA
- [x] **StorageClass `gp3`** — criptografada, política `Retain`, bind `WaitForFirstConsumer`

#### Observabilidade
- [x] **Métricas** — kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
- [x] **Logs** — Loki + Promtail DaemonSet
- [x] **Traces** — Tempo + OTel Collector (OTLP gRPC/HTTP + Zipkin)
- [x] **Auto-instrumentação zero-code** — OTel Operator com SDK injection (Node.js)
- [x] **Correlação trace→log** — Grafana com datasources pré-configurados

#### Ingress e Tráfego
- [x] **AWS Load Balancer Controller** via IRSA
- [x] **Terraform em duas camadas** (`infra/` → `apps/`) com remote state entre camadas

---

### 🔴 P0 — Obrigatório Antes de Produção

Itens que falhariam numa auditoria de segurança ou representam risco operacional imediato.

#### Segurança — Controle Plane
- [ ] **Logs do control plane EKS** — habilitar `cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]` no cluster; sem isso, não há rastreabilidade de quem fez o quê no cluster
- [ ] **Criptografia de Secrets em repouso (KMS)** — configurar `cluster_encryption_config` com uma CMK do KMS; atualmente os Kubernetes Secrets são armazenados sem criptografia no etcd
- [ ] **Restrição do endpoint público da API** — `cluster_endpoint_public_access_cidrs` está em `0.0.0.0/0` por padrão; limitar aos CIDRs de VPN/escritório ou migrar para endpoint privado

#### Segurança — Rede e Pods
- [ ] **Network Policies** — sem políticas de rede, qualquer pod comprometido pode alcançar qualquer outro pod, incluindo `kube-system`; implementar deny-all + allows explícitos por namespace
- [ ] **Pod Security Standards** — habilitar Pod Security Admission com perfil `Baseline` (mínimo) ou `Restricted`; impede containers privilegiados, `hostNetwork`, `hostPID`, mount de paths do host
- [ ] **Restrição do Security Group dos nodes** — [`sg.tf`](infra/sg.tf) abre **todas as portas** de `10.0.0.0/8`; limitar ao CIDR da VPC e apenas às portas necessárias (443, kubelet, etc.)

#### Confiabilidade
- [ ] **Cluster Autoscaler ou Karpenter** — o node group é estático (2–6, manual); sem autoscaler, o cluster não reage a picos de carga nem reduz custo em baixa utilização
- [ ] **3 Availability Zones** — atualmente 2 AZs; uma falha de AZ degrada capacidade em 50% e pode violar SLA; expandir para 3 AZs nos três bancos de subnets
- [ ] **TLS / cert-manager** — ALBs expostos sem HTTPS; integrar cert-manager com ACM ou Let's Encrypt para renovação automática de certificados

---

### 🟠 P1 — Primeiro Sprint Pós-Launch

Itens que não bloqueiam o go-live mas devem ser resolvidos nas primeiras semanas.

#### Segurança
- [ ] **External Secrets Operator** — integrar com AWS Secrets Manager ou SSM Parameter Store; atualmente segredos de aplicação vivem como Kubernetes Secrets em base64 sem rotação automática
- [ ] **Detecção de ameaças em runtime** — habilitar Amazon GuardDuty for EKS Runtime Monitoring ou implantar Falco; detecta escapes de container, execução de processos suspeitos, cryptomining
- [ ] **Scanning de imagens** — habilitar ECR Enhanced Scanning (Amazon Inspector) e bloquear imagens com CVEs críticos no pipeline de CI
- [ ] **Remover conta root dos admins do cluster** — `eks_admin_principal_arns` inclui o root da conta AWS; substituir por roles IAM com MFA; root nunca deve ser usado para workloads

#### Confiabilidade e Disponibilidade
- [ ] **PodDisruptionBudgets** — sem PDBs, um drain de node durante upgrade pode derrubar todos os pods de um serviço simultaneamente
- [ ] **Topology Spread Constraints** — pods do mesmo Deployment podem ser agendados no mesmo node/AZ; configurar spread por AZ e por node
- [ ] **Instances compute-optimized** — `t3.medium` é instância *burstable*; sob carga sustentada os créditos de CPU esgotam e a instância throttles; migrar para `m6i.large` ou `m7i.large` para workloads de produção
- [ ] **Probes de liveness/readiness** — padronizar probes em todos os workloads de aplicação; sem elas o Kubernetes não detecta pods travados

#### Observabilidade
- [ ] **Regras de alerting no Alertmanager** — Prometheus está instalado mas sem `PrometheusRule` ou `AlertmanagerConfig`; sem alertas, incidentes só são detectados manualmente
- [ ] **Integração PagerDuty/Slack** — configurar notificações para node not-ready, pod crash-looping, PVC cheio, deployment sem replicas disponíveis
- [ ] **Métricas do control plane** — API server, scheduler e controller-manager não estão sendo coletados; anomalias no cluster passam despercebidas

#### Custo
- [ ] **Spot instances para workloads tolerantes a falha** — observabilidade (Prometheus, Loki, Tempo) e apps stateless podem rodar em Spot com economia de 60–80%; configurar node group misto On-Demand + Spot
- [ ] **Loki com backend S3** — atualmente Loki usa EBS local; dados de log não sobrevivem à recriação do cluster; migrar para modo `SimpleScalable` com S3 como object store

---

### 🟡 P2 — Maturidade Operacional

Itens para clusters estabelecidos em produção que buscam maturidade enterprise.

#### Governança e Compliance
- [ ] **Engine de políticas (Kyverno ou OPA Gatekeeper)** — enforcement de políticas organizacionais: allowlist de registry de imagens, proibição de tag `latest`, labels obrigatórias, `securityContext` mínimo
- [ ] **RBAC por equipe** — atualmente só existe `cluster-admin`; definir Roles/ClusterRoles por função (dev, ops, read-only) com bindings por namespace
- [ ] **Cotas de recursos por namespace** — sem `ResourceQuota` e `LimitRange`, uma equipe pode esgotar CPU/memória do cluster inteiro
- [ ] **Integração SSO (IAM Identity Center / OIDC)** — substituir ARNs de usuários IAM individuais por roles federadas via Identity Provider corporativo (Okta, Azure AD)
- [ ] **CIS Benchmark e hardeneks** — executar `hardeneks` e Kubescape regularmente para medir aderência ao CIS EKS Benchmark

#### GitOps e CI/CD
- [ ] **GitOps (ArgoCD ou Flux)** — substituir `terraform apply` manual dos Helm releases por sincronização declarativa com o repositório Git; audit trail por deploy
- [ ] **Pipeline de segurança de supply chain** — assinatura de imagens (Cosign/AWS Signer), geração de SBOM, verificação de assinatura na admissão
- [ ] **Lint e scan de manifests no CI** — integrar Checkov, Polaris ou kube-score para bloquear configurações inseguras antes do merge

#### Confiabilidade Avançada
- [ ] **Velero — backup de cluster e PVs** — sem backup, a recriação do cluster perde dados de PVCs (Prometheus histórico, logs persistentes); configurar backup periódico para S3
- [ ] **NodeLocal DNSCache** — em clusters maiores, o CoreDNS torna-se gargalo; um DaemonSet de DNS local em cada node reduz latência e remove ponto único de falha de DNS
- [ ] **Vertical Pod Autoscaler (VPA)** — em modo recomendação para identificar pods sub ou super-dimensionados; complementa o HPA
- [ ] **HPA / KEDA por workload** — `node-ws` e outras aplicações sem autoscaling horizontal; KEDA para scaling baseado em eventos (SQS, Kafka)

#### Observabilidade Avançada
- [ ] **SLOs/SLIs com recording rules** — definir orçamentos de erro por serviço com alertas baseados em taxa de erros e latência em vez de métricas de infraestrutura
- [ ] **CloudTrail + Athena para auditoria de API AWS** — rastrear quais pods (via IRSA) chamaram quais APIs AWS e quando; pipeline CloudTrail → S3 → Athena
- [ ] **Kubecost ou OpenCost** — atribuição de custo por namespace/equipe/workload para chargeback e identificação de desperdício

#### Documentação Operacional
- [ ] **Runbooks operacionais** — procedimentos documentados para: upgrade de versão do EKS, substituição de nodes, recuperação de etcd, rollback de Helm release
- [ ] **Procedimento de break-glass** — acesso de emergência documentado com trilha de auditoria
- [ ] **Guia de DR** — estratégia documentada de recuperação: RPO/RTO por componente, procedimento de restore com Velero

---

## 🤝 Contribuindo

Contribuições são bem-vindas! Por favor, siga estas diretrizes:

1. **Fork o repositório**
2. **Crie um branch de funcionalidade**
   ```bash
   git checkout -b feature/nova-funcionalidade
   ```
3. **Commit suas mudanças**
   ```bash
   git commit -m 'Adiciona nova funcionalidade'
   ```
4. **Push para o branch**
   ```bash
   git push origin feature/nova-funcionalidade
   ```
5. **Abra um Pull Request**

### Diretrizes de Desenvolvimento

- Siga as melhores práticas do Terraform
- Use nomes de variáveis e recursos significativos
- Inclua campos `description` para todas as variáveis
- Escreva testes para novas funcionalidades
- Atualize a documentação para qualquer alteração

---

## 📄 Licença

Este projeto é software proprietário. Todos os direitos reservados.

---

## 📞 Suporte

Para perguntas ou problemas:
- Crie uma issue no repositório
- Entre em contato com os mantenedores diretamente
- Revise a seção de solução de problemas acima

---

**Última Atualização**: Março de 2026
**Mantenedor**: Equipe ps-sl
**Versão**: 1.2.0
