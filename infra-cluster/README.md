# infra-cluster

Primeira camada do cluster. Provisiona a rede AWS (VPC) e o plano de controle do EKS, além das roles IAM base e dos endpoints VPC necessários para que nodes e pods operem sem rotear tráfego pelo NAT Gateway.

Os outputs desta camada são lidos por `infra-resources` via remote state do S3 e repassados ao job `apps` pelo CI.

---

## Índice

1. [Visão Geral da Arquitetura](#visão-geral-da-arquitetura)
2. [Recursos](#recursos)
   - [VPC](#vpc--vpctf)
   - [VPC Endpoints](#vpc-endpoints--vpctf)
   - [EKS](#eks--ekstf)
   - [IAM](#iam--iamtf)
   - [Security Group](#security-group--sgtf)
3. [Detalhamento Técnico](#detalhamento-técnico)
   - [Design de Rede](#design-de-rede)
   - [Prefix Delegation](#prefix-delegation)
   - [EKS Access Entries](#eks-access-entries)
4. [Variáveis](#variáveis)
5. [Outputs](#outputs)
6. [Como Verificar](#como-verificar)
7. [Deploy](#deploy)

---

## Visão Geral da Arquitetura

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                           AWS · Region: us-east-2                             │
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────┐  │
│  │                           VPC  10.0.0.0/16                              │  │
│  │                                                                         │  │
│  │   ┌──────────────────────────────────────────────────────────────────┐  │  │
│  │   │  Subnets públicas — ALBs e NAT Gateways                          │  │  │
│  │   │  AZ-a  10.0.0.0/24    AZ-b  10.0.1.0/24    AZ-c  10.0.2.0/24   │  │  │
│  │   │  [ IGW ]  [ NAT GW ]  [ NAT GW ]  [ NAT GW ]                    │  │  │
│  │   └──────────────────────────────────────────────────────────────────┘  │  │
│  │                             │  (rotas privadas → NAT GW por AZ)          │  │
│  │   ┌──────────────────────────────────────────────────────────────────┐  │  │
│  │   │  Subnets privadas — nodes + pods (prefix delegation)             │  │  │
│  │   │  AZ-a  10.0.32.0/19   AZ-b  10.0.64.0/19  AZ-c  10.0.96.0/19  │  │  │
│  │   │                                                                  │  │  │
│  │   │  ┌─────────────────────────────────────────────────────────┐    │  │  │
│  │   │  │  EKS Cluster (Kubernetes 1.34)                          │    │  │  │
│  │   │  │  Managed control plane · OIDC · vpc-cni (prefix deleg.) │    │  │  │
│  │   │  └─────────────────────────────────────────────────────────┘    │  │  │
│  │   └──────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                         │  │
│  │  VPC Endpoints (Interface): ECR API · ECR DKR · STS · EC2              │  │
│  │  VPC Endpoint (Gateway): S3                                             │  │
│  │  VPC Flow Logs → CloudWatch Logs (30d)                                  │  │
│  └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                               │
│  IAM: node role · ALB Controller IRSA role                                   │
│  S3:  ps-sl-state-bucket-cavi-2 (infra-cluster/terraform.tfstate)            │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

## Recursos

### VPC — `vpc.tf`

| | |
|---|---|
| Módulo | `terraform-aws-modules/vpc/aws` v5.7.0 |
| CIDR | `10.0.0.0/16` |
| AZs | 3 (primeiras 3 AZs disponíveis na região) |
| NAT Gateways | 1 por AZ |

**Subnets públicas** — dimensionadas para ALBs e NAT Gateways. A AWS recomenda `/24` por AZ para ALBs que escalam horizontalmente.

| AZ | CIDR | Tags |
|---|---|---|
| AZ-a | `10.0.0.0/24` | `kubernetes.io/role/elb=1` |
| AZ-b | `10.0.1.0/24` | `kubernetes.io/role/elb=1` |
| AZ-c | `10.0.2.0/24` | `kubernetes.io/role/elb=1` |

**Subnets privadas** — nodes e pods compartilham a mesma subnet via prefix delegation. `/19` por AZ comporta 512 blocos `/28` (ver [Prefix Delegation](#prefix-delegation)).

| AZ | CIDR | Tags |
|---|---|---|
| AZ-a | `10.0.32.0/19` | `kubernetes.io/role/internal-elb=1` |
| AZ-b | `10.0.64.0/19` | `kubernetes.io/role/internal-elb=1` |
| AZ-c | `10.0.96.0/19` | `kubernetes.io/role/internal-elb=1` |

**VPC Flow Logs**
```
Tipo:   ALL (aceito + rejeitado)
Destino: CloudWatch Logs (/aws/vpc/...)
Retenção: 30 dias
IAM role: criada automaticamente pelo módulo
```

### VPC Endpoints — `vpc.tf`

Mantêm o tráfego de bootstrapping dos nodes, pulls de imagem ECR e troca de tokens IRSA dentro da rede AWS — sem cobranças de NAT Gateway e sem latência de ida e volta para a internet.

**Security Group dos endpoints (`vpc-endpoints-`)**
Permite HTTPS (443/TCP) de qualquer IP dentro do CIDR da VPC (`10.0.0.0/16`) para todos os endpoints Interface.

| Endpoint | Tipo | Finalidade |
|---|---|---|
| S3 | Gateway (gratuito) | Layers de imagem ECR armazenadas no S3; scripts de bootstrap de node |
| ECR API | Interface | Autenticação e metadados do registro ECR |
| ECR DKR | Interface | Pull de layers de imagem Docker |
| STS | Interface | `AssumeRoleWithWebIdentity` — troca de tokens OIDC por credenciais AWS para IRSA |
| EC2 | Interface | vpc-cni chama `AssignPrivateIpAddresses` e `UnassignPrivateIpAddresses` para alocar blocos `/28` nas ENIs durante scale-up de nodes |

**Por que o endpoint EC2?**
Com prefix delegation, o vpc-cni faz chamadas EC2 frequentes durante scale-up para atribuir novos prefixos `/28` às ENIs dos nodes. Sem o endpoint, cada chamada passa pelo NAT Gateway (latência + custo). Em escala, isso pode atrasar o provisionamento de pods.

### EKS — `eks.tf`

| | |
|---|---|
| Módulo | `terraform-aws-modules/eks/aws` v20.8.4 |
| Versão Kubernetes | `1.34` |
| Nome | `sl-eks-<sufixo-aleatório-8-chars>` |
| Subnets | Privadas (control plane ENIs nas subnets privadas) |
| Endpoint público | habilitado |
| Endpoint privado | habilitado |
| IRSA | habilitado (`enable_irsa = true`) |

**Addon vpc-cni**

O addon é configurado com `before_compute = true`, que instrui o módulo EKS a criar e configurar o addon _antes_ de criar qualquer node group. Isso garante que prefix delegation já esteja ativo no momento em que o primeiro node inicializa.

```
ENABLE_PREFIX_DELEGATION = "true"   # ativa alocação de blocos /28 em vez de IPs individuais
WARM_PREFIX_TARGET       = "1"      # mantém 1 bloco /28 reservado por node para starts rápidos
```

**Controle de acesso (Access Entries)**

```hcl
# Para cada ARN em eks_admin_principal_arns:
aws_eks_access_entry  → cria a entrada de autenticação (principal_arn → tipo STANDARD)
aws_eks_access_policy_association → associa AmazonEKSClusterAdminPolicy com escopo "cluster"
```

As entradas são criadas no mesmo job do cluster para que as camadas seguintes (`infra-resources`, `apps`) já possam autenticar via provider Kubernetes/Helm.

### IAM — `iam.tf`

**Role dos worker nodes**

```
aws_iam_role.node  →  ec2.amazonaws.com pode assumir esta role
  ├── AmazonEKSWorkerNodePolicy        # kubelet registra node, descreve EC2
  ├── AmazonEKS_CNI_Policy             # vpc-cni gerencia ENIs e prefixos /28
  └── AmazonEC2ContainerRegistryReadOnly  # pull de imagens do ECR
```

O nome da role inclui o nome do cluster (`${local.cluster_name}-node-role`) para evitar colisões entre múltiplos clusters na mesma conta.

**IRSA role do AWS Load Balancer Controller**

Criada aqui (não em `infra-resources`) porque o ARN é um output desta camada, consumido diretamente pelo job `apps` no CI sem passar por `infra-resources`.

```
module.alb_irsa_role (terraform-aws-modules/iam ~5.0)
  trust policy:  namespace kube-system, service account aws-load-balancer-controller
  política:      iam_policy.json (251 linhas)
                 ├── elasticloadbalancing:* (ALBs, listeners, target groups)
                 ├── ec2:Describe*, ec2:*SecurityGroup* (SGs para os ALBs)
                 ├── acm:ListCertificates, acm:DescribeCertificate (TLS)
                 ├── wafv2:* (WAF para ALBs)
                 └── shield:* (DDoS protection)
```

### Security Group — `sg.tf`

Security group adicional (`all_worker_management`) que é referenciado pelo launch template em `infra-resources`. Não substitui o security group gerenciado pelo módulo EKS — complementa-o.

| Regra | Direção | Protocolo | Origem/Destino |
|---|---|---|---|
| `all_worker_mgmt_ingress` | Inbound | todos | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` |
| `all_worker_mgmt_egress` | Outbound | todos | `0.0.0.0/0` |

> **Nota (Roadmap P0):** a regra de ingress abre todas as portas de todo o espaço RFC-1918. Em produção, restringir ao CIDR da VPC (`10.0.0.0/16`) e somente às portas necessárias (443 para API server, porta do kubelet, etc.).

---

## Detalhamento Técnico

### Design de Rede

```
CIDR da VPC:  10.0.0.0/16  (65.536 endereços)

Band pública   — 10.0.0.0/19  (primeiros 8.192 endereços)
  /24 por AZ:  10.0.0.0  10.0.1.0  10.0.2.0  [+5 AZs disponíveis]

Band privada   — 10.0.32.0/19+ (sequencial, incremento de 32 no 3º octeto)
  /19 por AZ:  10.0.32.0  10.0.64.0  10.0.96.0
  futuras AZs: 10.0.128.0  10.0.160.0  10.0.192.0
```

**Por que `/19` e não `/24` nas subnets privadas?**
Com prefix delegation, o vpc-cni reserva um bloco `/28` (16 IPs) por node em vez de IPs individuais. Um node `t3.medium` pode ter no máximo 3 ENIs × 2 prefixos = 6 blocos `/28` = 96 IPs de pod. Um `/24` comporta apenas 16 blocos `/28` — suficiente para 8 nodes antes de esgotar. Um `/19` comporta 512 blocos `/28` — suficiente para ~256 nodes.

### Prefix Delegation

Prefix delegation é diferente de custom networking:

| | Custom Networking | Prefix Delegation |
|---|---|---|
| Subnets de pods | Separadas das subnets de nodes (`intra`) | Mesma subnet dos nodes |
| IP do node no cluster | 1 IP (ENI primário) | 1 IP (ENI primário) |
| IPs de pods | Da subnet `intra` | Da subnet privada, em blocos `/28` |
| Complexidade | Alta (ENIConfig por AZ) | Baixa (apenas vars no vpc-cni) |
| Máximo de pods/node | Limitado pelas ENIs | Muito maior (96+ em `t3.medium`) |

**CIDR Reservations**

O primeiro `/20` de cada subnet privada é reservado exclusivamente para blocos `/28`:

```
10.0.32.0/19  →  reserva  10.0.32.0/20  para prefixos /28
10.0.64.0/19  →  reserva  10.0.64.0/20  para prefixos /28
10.0.96.0/19  →  reserva  10.0.96.0/20  para prefixos /28
```

Sem essa reserva, IPs secundários atribuídos individualmente (por outros recursos ou por nodes em fase de warm-up) podem fragmentar o espaço de endereçamento, causando falhas de alocação de prefixo com o erro `InsufficientCidrBlocks` quando um novo node inicializa.

**Fluxo de alocação de IPs**

```
Node inicializa
    │
    ▼
kubelet chama vpc-cni
    │
    ▼
vpc-cni → EC2 endpoint (via VPC Endpoint) → AssignPrivateIpAddresses
    │  (solicita prefixo /28 na subnet, não IPs individuais)
    ▼
EC2 atribui bloco /28 à ENI do node
    │
    ▼
vpc-cni adiciona rota local no node para o /28
    │
    ▼
Pod agendado recebe IP do /28 local (sem nova chamada EC2)
```

### EKS Access Entries

```
IDs usuário:  eks_admin_principal_arns (var)
                ├── arn:aws:iam::<account>:user/Felipe_Cavichiolli
                └── arn:aws:iam::<account>:root
      │
      ▼
aws_eks_access_entry  (type = STANDARD)
      │
      ▼
aws_eks_access_policy_association
  policy_arn: arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
  access_scope: { type = "cluster" }   ← acesso a todos os namespaces
```

**Por que Access Entries em vez de `aws-auth`?**

O `aws-auth` ConfigMap é um recurso Kubernetes gerenciado manualmente. Uma edição incorreta (YAML inválido, indentação errada) pode revogar _todo_ acesso administrativo ao cluster sem possibilidade de recuperação via kubectl — o único caminho seria via credenciais IAM temporárias do próprio plano de controle. Access Entries são gerenciadas via API do EKS, auditadas pelo CloudTrail e podem ser modificadas mesmo se o acesso kubectl estiver quebrado.

---

## Variáveis

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `aws_region` | `string` | `"us-east-2"` | Região AWS para todos os recursos |
| `kubernetes_version` | `number` | `1.34` | Versão do Kubernetes |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | CIDR da VPC |
| `eks_admin_principal_arns` | `list(string)` | ARNs do usuário e root | IAM principals com acesso cluster-admin via EKS Access Entries |

---

## Outputs

| Output | Tipo | Usado por | Descrição |
|---|---|---|---|
| `cluster_name` | `string` | infra-resources, apps (CI) | Nome gerado do cluster (com sufixo aleatório) |
| `cluster_endpoint` | `string` | infra-resources, apps (CI) | URL HTTPS da API do EKS |
| `cluster_ca` | `string` | infra-resources, apps (CI) | Certificado CA do cluster (base64) |
| `cluster_security_group_id` | `string` | — | SG do plano de controle (gerenciado pelo módulo EKS) |
| `node_security_group_id` | `string` | infra-resources | SG dos nodes (gerenciado pelo módulo EKS) |
| `node_role_arn` | `string` | infra-resources | ARN da role IAM dos worker nodes |
| `private_subnets` | `list(string)` | infra-resources | IDs das 3 subnets privadas |
| `worker_mgmt_sg_id` | `string` | infra-resources | SG adicional de gerenciamento (sg.tf) |
| `alb_irsa_role` | `string` | apps (CI) | ARN da IRSA role do AWS Load Balancer Controller |
| `oidc_provider` | `string` | infra-resources | URL do OIDC provider (sem `https://`) |
| `oidc_provider_arn` | `string` | infra-resources | ARN completo do OIDC provider |
| `vpc_id` | `string` | apps (CI) | ID da VPC |
| `aws_region` | `string` | — | Região AWS (repassada como conveniência) |

---

## Como Verificar

```bash
# Confirmar que o cluster está ativo
aws eks describe-cluster \
  --name $(terraform output -raw cluster_name) \
  --region us-east-2 \
  --query 'cluster.status'
# Esperado: "ACTIVE"

# Confirmar subnets criadas
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'Subnets[*].[CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Confirmar VPC Endpoints
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'VpcEndpoints[*].[ServiceName,State]' \
  --output table

# Confirmar Access Entries
aws eks list-access-entries \
  --cluster-name $(terraform output -raw cluster_name) \
  --region us-east-2

# Confirmar addon vpc-cni configurado com prefix delegation
aws eks describe-addon \
  --cluster-name $(terraform output -raw cluster_name) \
  --addon-name vpc-cni \
  --query 'addon.configurationValues' \
  --region us-east-2
```

---

## Deploy

```bash
cd infra-cluster
terraform init
terraform apply
```

Após o apply, exporte os outputs para uso nas camadas seguintes:

```bash
terraform output cluster_name
terraform output cluster_endpoint
terraform output cluster_ca
terraform output alb_irsa_role
terraform output vpc_id
```

No CI, o job `infra-cluster` do workflow `tf-deploy.yml` exporta `cluster_name`, `cluster_endpoint` e `cluster_ca` como outputs de step, consumidos automaticamente pelos jobs `infra-resources` e `apps`.

Para configurar o kubectl localmente após o apply:

```bash
aws eks update-kubeconfig \
  --region us-east-2 \
  --name $(terraform output -raw cluster_name)

kubectl get nodes   # ainda sem nodes — eles são criados em infra-resources
kubectl get pods -A # apenas pods do kube-system (CoreDNS, vpc-cni)
```
