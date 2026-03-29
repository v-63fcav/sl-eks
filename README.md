# sl-eks

[![Deploy](https://github.com/v-63fcav/sl-eks/actions/workflows/tf-deploy.yml/badge.svg)](https://github.com/v-63fcav/sl-eks/actions/workflows/tf-deploy.yml)
[![Destroy](https://github.com/v-63fcav/sl-eks/actions/workflows/tf-destroy.yml/badge.svg)](https://github.com/v-63fcav/sl-eks/actions/workflows/tf-destroy.yml)
![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A50.12-7B42BC?logo=terraform&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazonaws&logoColor=white)

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

Este projeto implementa uma plataforma completa de observabilidade Kubernetes na AWS EKS utilizando as melhores práticas de Infraestrutura como Código (IaC). A solução utiliza Terraform para gerenciamento declarativo de infraestrutura, EKS para orquestração de contêineres e o stack Prometheus/Grafana/Loki/Tempo para monitoramento abrangente dos três sinais: métricas, logs e traces.

### ✨ Funcionalidades Principais

- **Infraestrutura Declarativa**: Provisionamento em três camadas sequenciais com Terraform, estado remoto no S3
- **Alta Disponibilidade**: Cluster EKS multi-AZ com node group distribuído por 3 zonas de disponibilidade
- **Observabilidade Completa**: Stack integrado de métricas (Prometheus + Grafana), logs (Loki + Promtail) e traces (Tempo)
- **Tracing Distribuído**: Dois padrões de instrumentação — Zipkin via OTel Collector e auto-instrumentação zero-code via OTel Operator
- **Segurança**: Topologia de rede isolada, subnets privadas para nodes, IRSA para todos os componentes AWS, sem credenciais estáticas
- **CI/CD**: GitHub Actions com pipelines de deploy e destroy ordenados e com limpeza de recursos AWS externos ao Terraform

---

## 🏗️ Arquitetura

### ☁️ Infraestrutura AWS

```
┌───────────────────────────────────────────────────────────────────────────────────┐
│                              AWS · Region: us-east-2                              │
│  ┌─────────────────────────────────────────────────────────────────────────────┐  │
│  │                             VPC  10.0.0.0/16                                │  │
│  │                                                                             │  │
│  │  ┌──────────────────────────────┐  ┌──────────────────────────────────────┐ │  │
│  │  │  Subnets Públicas (ALB/NAT)  │  │  Subnets Privadas (Nodes + Pods)     │ │  │
│  │  │  10.0.0.0/24  AZ-a           │  │  10.0.32.0/19  AZ-a  (~8k IPs)      │ │  │
│  │  │  10.0.1.0/24  AZ-b           │  │  10.0.64.0/19  AZ-b  (~8k IPs)      │ │  │
│  │  │  10.0.2.0/24  AZ-c           │  │  10.0.96.0/19  AZ-c  (~8k IPs)      │ │  │
│  │  │                              │  │                                      │ │  │
│  │  │  IGW · NAT GW (×3 AZs)      │  │  t3.medium · 2–6 nodes              │ │  │
│  │  │  ALB — Grafana, apps         │  │  Prefix delegation (/28 por node)   │ │  │
│  │  └──────────────────────────────┘  └──────────────────────────────────────┘ │  │
│  │                                                                             │  │
│  │  ┌─────────────────────────────────────────────────────────────────────┐   │  │
│  │  │  EKS Cluster (Kubernetes 1.34)                                      │   │  │
│  │  │  Managed Control Plane · OIDC · EBS CSI addon · VPC CNI addon       │   │  │
│  │  │  EKS Access Entries (cluster-admin sem aws-auth ConfigMap)          │   │  │
│  │  └─────────────────────────────────────────────────────────────────────┘   │  │
│  │                                                                             │  │
│  │  VPC Endpoints: S3 (Gateway) · ECR API · ECR DKR · STS · EC2              │  │
│  │  VPC Flow Logs → CloudWatch Logs (retenção 30 dias)                        │  │
│  └─────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                   │
│  S3 (Terraform state · encrypt=true)   CloudWatch   ECR                          │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### 📊 Stack de Observabilidade

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

### 🔄 Fases de Deploy

A solução é implantada em três fases sequenciais, cada uma com estado Terraform independente no S3:

1. **`infra-cluster`** — VPC, EKS control plane, IAM base, VPC Endpoints
2. **`infra-resources`** — Node group, addon EBS CSI Driver, StorageClass gp3
3. **`apps`** — Helm releases de observabilidade e aplicações

---

## 📦 Pré-requisitos

### 🛠️ Ferramentas

| Ferramenta | Versão mínima | Finalidade |
|---|---|---|
| Terraform | ≥ 0.12 | Provisionamento de infraestrutura |
| AWS CLI | ≥ 2.x | Autenticação e `aws eks get-token` |
| kubectl | compatível com 1.34 | Interação com o cluster |
| Helm | ≥ 3.x | Instalação manual de charts (opcional) |

### ☁️ Requisitos AWS

- Conta AWS ativa com credenciais configuradas no AWS CLI
- Permissões para `iam:*`, `ec2:*`, `eks:*`, `s3:*` e `elasticloadbalancing:*`
- Bucket S3 `ps-sl-state-bucket-cavi-2` criado na região `us-east-2` antes do primeiro `terraform init`
- Quotas de serviço suficientes para: clusters EKS, VPC com subnets em 3 AZs, NAT Gateways e Load Balancers

### ⚙️ Configuração GitHub Actions

Os seguintes secrets devem estar configurados no repositório:

| Secret | Descrição |
|---|---|
| `AWS_ACCESS_KEY_ID` | Credencial de acesso AWS |
| `AWS_SECRET_ACCESS_KEY` | Credencial de acesso AWS |

---

## 📁 Estrutura do Projeto

```
sl-eks/
├── infra-cluster/              # Camada 1 — VPC, EKS control plane, IAM base
│   ├── vpc.tf                  # VPC, subnets, NAT GWs, Flow Logs, VPC Endpoints
│   ├── eks.tf                  # Cluster EKS, addon vpc-cni, Access Entries
│   ├── iam.tf                  # Node role, IRSA role do ALB Controller
│   ├── iam_policy.json         # Política IAM do ALB Controller
│   ├── sg.tf                   # Security group dos worker nodes
│   ├── outputs.tf              # Outputs consumidos pelas camadas seguintes
│   ├── variables.tf            # Variáveis de entrada
│   ├── versions.tf             # Versões dos providers
│   ├── providers.tf            # Configuração dos providers
│   ├── backend.tf              # Backend S3
│   └── README.md
├── infra-resources/            # Camada 2 — Node group, addons, StorageClass
│   ├── node-group.tf           # Launch template e managed node group
│   ├── addons.tf               # Addon EBS CSI Driver
│   ├── iam.tf                  # IRSA role do EBS CSI Driver
│   ├── storage.tf              # StorageClass gp3
│   ├── remote-state.tf         # Leitura do state de infra-cluster
│   ├── outputs.tf              # Outputs repassados ao job apps
│   ├── variables.tf            # Variáveis de entrada
│   ├── versions.tf             # Versões dos providers
│   ├── providers.tf            # Configuração dos providers
│   ├── backend.tf              # Backend S3
│   └── README.md
├── apps/                       # Camada 3 — Helm releases
│   ├── helm.tf                 # Todos os Helm releases (observabilidade + apps)
│   ├── values/                 # Values files dos charts externos
│   │   ├── values-alb-controller.yaml
│   │   ├── values-kube-prometheus-stack.yaml
│   │   ├── values-loki.yaml
│   │   ├── values-tempo.yaml
│   │   ├── values-otel-collector.yaml
│   │   └── values-otel-operator.yaml
│   ├── charts/                 # Charts Helm locais
│   │   ├── app-chart/          # Chart genérico Node.js com OTel auto-instrumentação
│   │   ├── otel-test-app-chart/# Chart do fake-service (Zipkin)
│   │   └── otel-platform-chart/# Instrumentation CRs compartilhados
│   ├── variables.tf
│   ├── versions.tf
│   ├── providers.tf
│   ├── backend.tf
│   └── README.md
└── .github/workflows/
    ├── tf-deploy.yml           # Deploy: infra-cluster → infra-resources → apps
    └── tf-destroy.yml          # Destroy: apps → infra-resources → infra-cluster
```

---

## 🏢 Componentes de Infraestrutura

> Documentação completa em [infra-cluster/README.md](infra-cluster/README.md) e [infra-resources/README.md](infra-resources/README.md)

### 🌐 Rede

A VPC usa subnets por banda para separar cargas de trabalho:

| Banda | Range | Prefixo/AZ | Uso |
|---|---|---|---|
| Pública | `10.0.0.0–10.0.2.255` | `/24` | ALBs, NAT Gateways |
| Privada | `10.0.32.0–10.0.96.255` | `/19` (~8k IPs) | Nodes + pods (prefix delegation) |

- **Prefix delegation (vpc-cni)**: cada node reserva um bloco `/28` para pods, sem subnet separada. `WARM_PREFIX_TARGET=1` mantém um bloco reservado por node para starts rápidos.
- **NAT Gateway por AZ**: elimina single point of failure e cobranças de tráfego inter-AZ.
- **VPC Endpoints**: S3 (Gateway), ECR API, ECR DKR, STS e EC2 mantêm pulls de imagem, tokens IRSA e chamadas do vpc-cni dentro da rede AWS, sem passar pelo NAT Gateway.
- **VPC Flow Logs**: captura todo o tráfego no CloudWatch Logs com retenção de 30 dias.

### 💻 Computação e Identidade

- **Cluster EKS** v1.34, endpoints público e privado habilitados
- **Node group gerenciado**: `t3.medium` (AL2023), 2 nodes base, escala até 6, nas subnets privadas
- **IRSA**: EBS CSI Driver e ALB Controller sem credenciais estáticas; ambas as roles vinculadas a service accounts específicas via OIDC
- **EKS Access Entries**: acesso admin via API moderna do EKS, sem edição manual do `aws-auth` ConfigMap

---

## 🚀 Componentes de Aplicação

> Documentação completa em [apps/README.md](apps/README.md)

### 📊 Stack de Observabilidade

| Componente | Chart | Função | Sinal |
|---|---|---|---|
| **kube-prometheus-stack** | prometheus-community v69.3.1 | Prometheus + Grafana + Alertmanager | Métricas |
| **Loki** | grafana v6.29.0 | Armazenamento de logs (SingleBinary, 20 GiB) | Logs |
| **Promtail** | grafana | Coleta de logs de todos os nodes (DaemonSet) | Logs |
| **Tempo** | grafana v1.14.0 | Armazenamento de traces (24h retenção, 20 GiB) | Traces |
| **OTel Collector** | open-telemetry v0.118.0 | Gateway OTLP — recebe e roteia os três sinais | Métricas / Logs / Traces |
| **OTel Operator** | open-telemetry | Auto-instrumentação zero-code via webhook mutante | — |
| **otel-platform** | local | Instrumentation CRs compartilhados por namespace | — |
| **ALB Controller** | aws | Provisiona ALBs a partir de recursos Ingress | — |

### 🧪 Aplicações de Exemplo

| Aplicação | Imagem | Instrumentação | Protocolo de tracing |
|---|---|---|---|
| **node-ws** | `node:20-alpine` | Zero-code (OTel Operator SDK inject) | OTLP/HTTP → OTel Collector → Tempo |
| **otel-test-app** | `nicholasjackson/fake-service:v0.26.2` | Built-in (Zipkin) | Zipkin → OTel Collector → Tempo |

---

## 🚦 Deploy

### 🤖 Via GitHub Actions (recomendado)

Acione manualmente o workflow `tf-deploy.yml` ou faça push para `main`. O pipeline executa `validate` e `plan` antes de cada `apply`, na ordem: `infra-cluster` → `infra-resources` → `apps`.

### 💻 Via linha de comando

```bash
# 1. Infraestrutura base — VPC + EKS control plane
cd infra-cluster
terraform init && terraform apply

# 2. Recursos do cluster — node group + addons + StorageClass
cd ../infra-resources
terraform init
terraform apply \
  -var="cluster_name=$(cd ../infra-cluster && terraform output -raw cluster_name)" \
  -var="kube_host=$(cd ../infra-cluster && terraform output -raw cluster_endpoint)" \
  -var="kube_ca=$(cd ../infra-cluster && terraform output -raw cluster_ca)"

# 3. Aplicações — Helm releases de observabilidade e apps
cd ../apps
terraform init
terraform apply \
  -var="cluster_name=$(cd ../infra-cluster && terraform output -raw cluster_name)" \
  -var="kube_host=$(cd ../infra-cluster && terraform output -raw cluster_endpoint)" \
  -var="kube_ca=$(cd ../infra-cluster && terraform output -raw cluster_ca)" \
  -var="alb_irsa_role=$(cd ../infra-resources && terraform output -raw alb_irsa_role)" \
  -var="vpc_id=$(cd ../infra-resources && terraform output -raw vpc_id)"
```

**Após o apply:**

```bash
# Configurar kubectl
aws eks update-kubeconfig \
  --region us-east-2 \
  --name $(cd infra-cluster && terraform output -raw cluster_name)

# Verificar nodes
kubectl get nodes

# Obter URLs dos ALBs
kubectl get ingress -n monitoring   # Grafana
kubectl get ingress -n default      # node-ws, otel-test-app
```

### 🗑️ Destroy

Use o workflow `tf-destroy.yml`. Ele executa na ordem inversa com limpeza de recursos AWS externos ao Terraform (ALBs, finalizers do Prometheus Operator, security groups órfãos).

> **Atenção:** destruir `infra-cluster` remove a VPC e o EKS. Não há rollback automático. Destrua `apps` e `infra-resources` primeiro.

---

## 🔐 Acesso e Credenciais

### 📊 Grafana

```bash
# Obter a URL do ALB
kubectl get ingress -n monitoring \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
```

- **Usuário**: `admin`
- **Senha**: `changeme` (definida em `apps/values/values-kube-prometheus-stack.yaml`)
- Datasources pré-configurados: **Prometheus**, **Loki**, **Tempo** (com correlação trace→log)

> Altere as credenciais padrão antes de usar em produção.

### 🧪 Aplicações de Exemplo

```bash
# URL do node-ws
kubectl get ingress node-ws -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# URL do otel-test-app
kubectl get ingress otel-test-app -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Gerar traces (substitua $ALB pelo hostname acima)
for i in $(seq 1 20); do curl -s http://$ALB/ > /dev/null; done

# Ver traces: Grafana → Explore → Tempo → Service Name: node-ws
```

### ☁️ Console AWS

- Cluster EKS: `Amazon EKS > Clusters`
- Load Balancers: `EC2 > Load Balancers`
- VPC e subnets: `VPC > Your VPCs`
- Flow Logs: `CloudWatch > Log groups > /aws/vpc/flowlogs`

---

## ⚙️ Configuração

### 📝 Variáveis Terraform

```hcl
# infra-cluster/variables.tf
variable "aws_region"          { default = "us-east-2" }
variable "kubernetes_version"  { default = 1.34 }
variable "vpc_cidr"            { default = "10.0.0.0/16" }

# Lista de ARNs IAM que receberão cluster-admin via EKS Access Entries
# Nunca incluir o root da conta em produção
variable "eks_admin_principal_arns" {
  type    = list(string)
  default = ["arn:aws:iam::659934583510:user/Felipe_Cavichiolli"]
}
```

### ⛵ Values Helm

Cada componente tem seu arquivo de values em `apps/values/`. Customizações comuns:

```yaml
# apps/values/values-kube-prometheus-stack.yaml
prometheus:
  prometheusSpec:
    retention: 15d           # retenção de métricas (padrão)
    retentionSize: "40GiB"   # limite por tamanho
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 50Gi  # volume EBS do Prometheus

# apps/values/values-tempo.yaml
tempo:
  retention: 24h          # Retencao de traces (curta - aumente conforme necessario)

# apps/values/values-loki.yaml
singleBinary:
  persistence:
    size: 20Gi               # volume de logs
```

### 📈 Escalamento do Node Group

Ajuste em `infra-resources/node-group.tf`:

```hcl
scaling_config {
  min_size     = 2   # mínimo de nodes sempre ativos
  max_size     = 6   # limite para escala manual (sem autoscaler instalado)
  desired_size = 2   # tamanho inicial
}
```

---

## 🛠️ Solução de Problemas

### 1. Nodes não aparecem (`kubectl get nodes` vazio)

```bash
# Verificar status do node group
aws eks describe-nodegroup \
  --cluster-name <cluster_name> \
  --nodegroup-name node-group \
  --region us-east-2

# Verificar eventos recentes do cluster
kubectl get events --sort-by='.lastTimestamp' -A | tail -20
```

### 2. Grafana não acessível

```bash
# Verificar se o Ingress tem hostname do ALB
kubectl get ingress -n monitoring

# Verificar se o ALB Controller está rodando
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Ver logs do ALB Controller
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller --tail=30
```

### 3. Prometheus não coletando métricas

```bash
# Verificar targets via port-forward
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Acesse http://localhost:9090/targets — todos devem estar UP
```

### 4. Traces não aparecem no Tempo/Grafana

```bash
# Verificar se o OTel Collector está recebendo spans
kubectl logs -n monitoring \
  -l app.kubernetes.io/name=opentelemetry-collector --tail=30

# Verificar se o Operator está rodando e o webhook está registrado
kubectl get pods -n opentelemetry-operator-system
kubectl get mutatingwebhookconfiguration | grep opentelemetry

# Verificar se o SDK foi injetado no pod node-ws
kubectl describe pod -n default -l app.kubernetes.io/name=node-ws \
  | grep -A5 'Init Containers'
```

### 5. Lock do estado Terraform

```bash
# Forçar desbloqueio (use o LOCK_ID exibido no erro)
terraform force-unlock <LOCK_ID>
```

### 🔍 Debug detalhado

```bash
export TF_LOG=DEBUG
terraform apply
```

---

## 🗺️ Roadmap

Este roadmap mapeia o estado atual em relação ao padrão de referência para clusters EKS enterprise-grade, baseado no [AWS EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/).

---

### ✅ Concluído

#### 🌐 Rede
- [x] **VPC multi-AZ** — 3 AZs com subnets públicas (`/24`) e privadas (`/19`)
- [x] **Prefix delegation (vpc-cni)** — `ENABLE_PREFIX_DELEGATION=true`; cada node reserva um bloco `/28` (16 IPs) para pods sem subnet separada; `WARM_PREFIX_TARGET=1` mantém um bloco reservado por node para starts rápidos
- [x] **NAT Gateway por AZ** — elimina ponto único de falha e cobranças de tráfego inter-AZ
- [x] **VPC Endpoints** — S3 (Gateway), ECR API, ECR DKR, STS e EC2; pulls de imagem e tokens IRSA não passam pelo NAT Gateway
- [x] **VPC Flow Logs** — captura tipo `ALL` no CloudWatch Logs, retenção 30 dias
- [x] **CIDR Reservations** — primeiro `/20` de cada subnet privada reservado para blocos `/28` do vpc-cni, evitando fragmentação do espaço de endereçamento

#### 💻 Computação e Identidade
- [x] **Cluster EKS gerenciado** v1.34, endpoints público e privado habilitados
- [x] **Node group gerenciado** — `AL2023_x86_64_STANDARD`, escala de 2 a 6 nodes nas subnets privadas
- [x] **IRSA para todos os componentes AWS** — EBS CSI Driver e ALB Controller sem credenciais estáticas
- [x] **EKS Access Entries** — acesso admin via API moderna (sem edição manual do `aws-auth` ConfigMap)
- [x] **Addon EBS CSI Driver** gerenciado pelo EKS com IRSA
- [x] **StorageClass `gp3`** — criptografada, política `Retain`, bind `WaitForFirstConsumer`

#### 📊 Observabilidade
- [x] **Métricas** — kube-prometheus-stack (Prometheus + Grafana + Alertmanager + Node Exporter + kube-state-metrics)
- [x] **Logs** — Loki (SingleBinary) + Promtail DaemonSet
- [x] **Traces** — Tempo + OTel Collector com receivers OTLP gRPC/HTTP e Zipkin
- [x] **Auto-instrumentação zero-code** — OTel Operator com SDK injection para Node.js
- [x] **Correlação trace→log** — datasource Tempo no Grafana pré-configurado com `tracesToLogsV2` apontando para Loki
- [x] **ALB Controller** via IRSA
- [x] **Terraform em três camadas** com remote state entre camadas

---

### 🔴 P0 — Obrigatório Antes de Produção

Itens que falhariam numa auditoria de segurança ou representam risco operacional imediato.

#### 🔒 Segurança — Control Plane
- [ ] **Logs do control plane EKS** — habilitar `cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]`; sem isso não há rastreabilidade de quem fez o quê no cluster
- [ ] **Criptografia de Secrets em repouso (KMS)** — configurar `cluster_encryption_config` com CMK do KMS; atualmente os Kubernetes Secrets são armazenados sem criptografia adicional no etcd
- [ ] **Restrição do endpoint público da API** — `cluster_endpoint_public_access_cidrs` está em `0.0.0.0/0`; limitar aos CIDRs de VPN/escritório ou migrar para endpoint privado

#### 🛡️ Segurança — Rede e Pods
- [ ] **Network Policies** — sem políticas de rede, qualquer pod comprometido pode alcançar qualquer outro pod no cluster; implementar deny-all + allows explícitos por namespace
- [ ] **Pod Security Standards** — habilitar Pod Security Admission com perfil `Baseline` ou `Restricted`; impede containers privilegiados, `hostNetwork`, `hostPID` e mount de paths do host
- [ ] **Restringir Security Group dos nodes** — `sg.tf` abre todas as portas dos ranges RFC-1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`); limitar ao CIDR da VPC e às portas estritamente necessárias (443, kubelet 10250)

#### 🔧 Confiabilidade
- [ ] **Cluster Autoscaler ou Karpenter** — o node group é estático (escala manual); sem autoscaler o cluster não reage a picos de carga nem reduz custo em baixa utilização
- [ ] **TLS / cert-manager** — ALBs expostos sem HTTPS; integrar cert-manager com ACM ou Let's Encrypt para renovação automática de certificados

---

### 🟠 P1 — Primeiro Sprint Pós-Launch

Itens que não bloqueiam o go-live, mas devem ser resolvidos nas primeiras semanas.

#### 🔒 Segurança
- [ ] **External Secrets Operator** — integrar com AWS Secrets Manager ou SSM Parameter Store; atualmente segredos de aplicação são Kubernetes Secrets em base64 sem rotação automática
- [ ] **Detecção de ameaças em runtime** — habilitar Amazon GuardDuty for EKS Runtime Monitoring ou implantar Falco; detecta escapes de container, processos suspeitos e cryptomining
- [ ] **Scanning de imagens** — habilitar ECR Enhanced Scanning (Amazon Inspector) e bloquear imagens com CVEs críticos no CI
- [ ] **Remover root da conta dos admins** — `eks_admin_principal_arns` inclui o root da conta AWS; substituir por roles IAM com MFA

#### 🔧 Confiabilidade e Disponibilidade
- [ ] **PodDisruptionBudgets** — sem PDBs, um drain de node durante upgrade pode derrubar todos os pods de um serviço simultaneamente
- [ ] **Topology Spread Constraints** — pods do mesmo Deployment podem ser agendados no mesmo node ou AZ; configurar spread por AZ e por node
- [ ] **Instâncias compute-optimized** — `t3.medium` é burstable; sob carga sustentada os créditos de CPU esgotam e a instância faz throttle; migrar para `m6i.large` ou `m7i.large` para produção
- [ ] **Probes de liveness/readiness** — padronizar probes em todos os workloads de aplicação

#### 📊 Observabilidade
- [ ] **Regras de alerting no Alertmanager** — Prometheus instalado sem `PrometheusRule` ou `AlertmanagerConfig`; sem alertas, incidentes são detectados apenas manualmente
- [ ] **Integração PagerDuty/Slack** — notificações para node not-ready, pod crash-looping, PVC cheio e deployment sem réplicas
- [ ] **Métricas do control plane** — API server, scheduler e controller-manager não estão sendo coletados

#### 💰 Custo
- [ ] **Spot instances para workloads tolerantes a falha** — observabilidade stateless e apps de teste podem rodar em Spot com economia de 60–80%
- [ ] **Loki com backend S3** — Loki usa EBS local; dados não sobrevivem à recriação do cluster; migrar para `SimpleScalable` com S3

---

### 🟡 P2 — Maturidade Operacional

Itens para clusters estabelecidos em produção que buscam maturidade enterprise.

#### ⚖️ Governança e Compliance
- [ ] **Engine de políticas (Kyverno ou OPA Gatekeeper)** — enforcement de allowlist de registry, proibição de tag `latest`, labels obrigatórias, `securityContext` mínimo
- [ ] **RBAC por equipe** — atualmente só existe `cluster-admin`; definir Roles/ClusterRoles por função (dev, ops, read-only) com bindings por namespace
- [ ] **Cotas de recursos por namespace** — sem `ResourceQuota` e `LimitRange`, uma equipe pode esgotar CPU/memória do cluster inteiro
- [ ] **Integração SSO (IAM Identity Center / OIDC)** — substituir ARNs de usuários IAM individuais por roles federadas via Identity Provider corporativo

#### 🔄 GitOps e CI/CD
- [ ] **GitOps (ArgoCD ou Flux)** — substituir `terraform apply` dos Helm releases por sincronização declarativa com o Git; audit trail por deploy
- [ ] **Pipeline de supply chain security** — assinatura de imagens (Cosign), geração de SBOM, verificação de assinatura na admissão
- [ ] **Lint e scan de manifests no CI** — integrar Checkov, Polaris ou kube-score para bloquear configurações inseguras antes do merge

#### 🔧 Confiabilidade Avançada
- [ ] **Velero — backup de cluster e PVs** — sem backup, a recriação do cluster perde dados de PVCs (Prometheus histórico, logs persistentes)
- [ ] **Vertical Pod Autoscaler (VPA)** — em modo recomendação para identificar pods sub ou super-dimensionados
- [ ] **HPA / KEDA por workload** — `node-ws` sem autoscaling horizontal; KEDA para scaling baseado em eventos (SQS, Kafka)

#### 📊 Observabilidade Avançada
- [ ] **SLOs/SLIs com recording rules** — orçamentos de erro por serviço com alertas baseados em taxa de erros e latência
- [ ] **CloudTrail + Athena para auditoria de API AWS** — rastrear quais pods (via IRSA) chamaram quais APIs AWS e quando
- [ ] **Kubecost ou OpenCost** — atribuição de custo por namespace/equipe/workload

#### 📚 Documentação Operacional
- [ ] **Runbooks operacionais** — procedimentos para: upgrade de versão do EKS, substituição de nodes, rollback de Helm release
- [ ] **Procedimento de break-glass** — acesso de emergência documentado com trilha de auditoria
- [ ] **Guia de DR** — RPO/RTO por componente, procedimento de restore com Velero

---

## 🤝 Contribuindo

1. Fork o repositório
2. Crie um branch de funcionalidade: `git checkout -b feature/nova-funcionalidade`
3. Commit suas mudanças: `git commit -m 'feat: adiciona nova funcionalidade'`
4. Push para o branch: `git push origin feature/nova-funcionalidade`
5. Abra um Pull Request

### 📌 Diretrizes

- Siga as boas práticas do Terraform (variáveis com `description`, outputs documentados, seções comentadas nos `.tf`)
- Atualize o README da camada afetada para qualquer mudança de recurso ou comportamento
- Teste o destroy antes de abrir o PR — recursos AWS órfãos bloqueiam deploys futuros

---

## 📄 Licença

Este projeto é software proprietário. Todos os direitos reservados.
