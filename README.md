# sl-eks

[![Deploy](https://github.com/v-63fcav/sl-eks/actions/workflows/tf-deploy.yml/badge.svg)](https://github.com/v-63fcav/sl-eks/actions/workflows/tf-deploy.yml)
[![Destroy](https://github.com/v-63fcav/sl-eks/actions/workflows/tf-destroy.yml/badge.svg)](https://github.com/v-63fcav/sl-eks/actions/workflows/tf-destroy.yml)
![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A50.12-7B42BC?logo=terraform&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazonaws&logoColor=white)

Cluster EKS na AWS com plataforma de observabilidade completa (métricas, logs, traces) e aplicações de exemplo instrumentadas com OpenTelemetry. Toda a infraestrutura é provisionada por Terraform e implantada via GitHub Actions em três camadas sequenciais.

---

## Visão Geral da Arquitetura

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            GitHub Actions                                │
│  tf-deploy.yml: infra-cluster → infra-resources → apps                  │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                          AWS (us-east-2)                                 │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │  VPC 10.0.0.0/16                                                  │   │
│  │  Subnets públicas  (ALBs, NAT GWs)  ◄── internet                 │   │
│  │  Subnets privadas  (nodes + pods)                                 │   │
│  │                                                                   │   │
│  │  ┌─────────────────────────────────────────────────────────────┐  │   │
│  │  │  EKS Cluster (Kubernetes 1.34)                              │  │   │
│  │  │                                                             │  │   │
│  │  │  Node Group  t3.medium · AL2023 · 2–6 nodes                │  │   │
│  │  │                                                             │  │   │
│  │  │  namespace: monitoring          namespace: default          │  │   │
│  │  │  ├─ Prometheus                  ├─ node-ws (OTLP)          │  │   │
│  │  │  ├─ Grafana ──── ALB           └─ otel-test-app (Zipkin)   │  │   │
│  │  │  ├─ Loki                                                    │  │   │
│  │  │  ├─ Tempo                                                   │  │   │
│  │  │  ├─ OTel Collector                                          │  │   │
│  │  │  └─ OTel Operator                                           │  │   │
│  │  └─────────────────────────────────────────────────────────────┘  │   │
│  └───────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  S3 (Terraform state)   ECR (imagens)   CloudWatch (VPC Flow Logs)      │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Estrutura do Repositório

```
sl-eks/
├── infra-cluster/        # VPC, EKS control plane, IAM base, VPC Endpoints
├── infra-resources/      # Node group, EBS CSI Driver, StorageClass gp3
├── apps/                 # Helm releases (observabilidade + aplicações)
│   ├── charts/           # Charts Helm locais (app-chart, otel-*)
│   └── values/           # Values files dos charts externos
└── .github/workflows/    # Pipelines de deploy e destroy
```

Cada camada mantém seu próprio estado Terraform no S3 e é executada em sequência pelo CI. A camada seguinte consome os outputs da anterior via variáveis de ambiente ou remote state.

---

## Pré-requisitos

| Ferramenta | Versão mínima | Finalidade |
|---|---|---|
| Terraform | ≥ 0.12 | Provisionamento de infraestrutura |
| AWS CLI | ≥ 2.x | Autenticação e `aws eks get-token` |
| kubectl | compatível com 1.34 | Interação com o cluster |
| Helm | ≥ 3.x | Instalação manual de charts (opcional) |

A conta AWS precisa de permissões para `iam:*`, `ec2:*`, `eks:*`, `s3:*` e `elasticloadbalancing:*`.

---

## Deploy

### Via GitHub Actions (recomendado)

Acione manualmente o workflow `tf-deploy.yml` ou faça push para `main`.
A execução é: `infra-cluster` → `infra-resources` → `apps`.

### Via linha de comando

```bash
# 1. Infraestrutura base — VPC + EKS control plane
cd infra-cluster
terraform init && terraform apply

# 2. Recursos do cluster — node group + addons + StorageClass
cd ../infra-resources
terraform init
terraform apply \
  -var="cluster_name=<cluster_name>" \
  -var="kube_host=<cluster_endpoint>" \
  -var="kube_ca=<cluster_ca>"

# 3. Aplicações — Helm releases de observabilidade e apps
cd ../apps
terraform init
terraform apply \
  -var="cluster_name=<cluster_name>" \
  -var="kube_host=<cluster_endpoint>" \
  -var="kube_ca=<cluster_ca>" \
  -var="alb_irsa_role=<alb_irsa_role>" \
  -var="vpc_id=<vpc_id>"
```

Os valores entre `<>` são obtidos dos outputs da camada anterior (`terraform output`).

---

## Destroy

Use o workflow `tf-destroy.yml`. Ele executa na ordem inversa:
`apps` → `infra-resources` → `infra-cluster`.

O workflow inclui etapas de limpeza para recursos externos ao Terraform: exclusão de Ingress (e consequente desprovisionamento dos ALBs), remoção de finalizers do Prometheus Operator e verificação de security groups órfãos.

> **Atenção:** destruir `infra-cluster` remove a VPC, o EKS e todo o estado de rede. Não há rollback automático.

---

## Documentação por Camada

| Camada | README | Descrição |
|---|---|---|
| `infra-cluster/` | [README](infra-cluster/README.md) | VPC, EKS control plane, IAM, VPC Endpoints |
| `infra-resources/` | [README](infra-resources/README.md) | Node group, EBS CSI Driver, StorageClass gp3 |
| `apps/` | [README](apps/README.md) | Plataforma de observabilidade e aplicações |

---

## Estado Terraform

Todos os estados são armazenados no S3 com criptografia habilitada (`encrypt = true`).

| Camada | Bucket | Key |
|---|---|---|
| `infra-cluster` | `ps-sl-state-bucket-cavi-2` | `infra-cluster/terraform.tfstate` |
| `infra-resources` | `ps-sl-state-bucket-cavi-2` | `infra-resources/terraform.tfstate` |
| `apps` | `ps-sl-state-bucket-cavi-2` | `terraform-apps.tfstate` |

O bucket deve existir antes do primeiro `terraform init`. Região: `us-east-2`.
