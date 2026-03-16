# infra-cluster

Primeira camada do cluster. Provisiona a rede AWS (VPC) e o plano de controle do EKS, além das roles IAM base e dos endpoints VPC necessários para que nodes e pods operem sem rotear tráfego pelo NAT Gateway.

Os outputs desta camada são consumidos por `infra-resources` via remote state do S3 e passados ao job `apps` pelo CI.

---

## Recursos Criados

### VPC — `vpc.tf`

Layout de rede de duas camadas: subnets públicas para ALBs e NAT Gateways, subnets privadas para nodes e pods.

| Recurso | Configuração |
|---|---|
| VPC | `10.0.0.0/16`, DNS hostnames e resolução habilitados |
| Subnets públicas | `10.0.0.0/24`, `10.0.1.0/24`, `10.0.2.0/24` — uma por AZ |
| Subnets privadas | `10.0.32.0/19`, `10.0.64.0/19`, `10.0.96.0/19` — uma por AZ |
| NAT Gateways | Um por AZ (`one_nat_gateway_per_az = true`) |
| VPC Flow Logs | Tipo `ALL`, retenção 30 dias no CloudWatch |

**Por que `/19` nas subnets privadas?**
Com prefix delegation habilitado no vpc-cni, cada node reserva um bloco `/28` inteiro (16 IPs) para pods. Um `/19` comporta 512 blocos `/28`, o que suporta até 512 nodes por subnet antes de exaurir o espaço de endereçamento.

**CIDR Reservations**
O primeiro `/20` de cada subnet privada é reservado exclusivamente para blocos `/28` do vpc-cni. Sem essa reserva, IPs secundários avulsos podem fragmentar o espaço de endereçamento ao longo do tempo, causando falhas de alocação de prefixo com `InsufficientCidrBlocks`.

### VPC Endpoints — `vpc.tf`

Mantêm o tráfego de bootstrapping, pulls de imagem e troca de tokens IRSA dentro da rede AWS, reduzindo custo de NAT Gateway e latência.

| Endpoint | Tipo | Finalidade |
|---|---|---|
| S3 | Gateway | Layers de imagem ECR e arquivos de bootstrap de node |
| ECR API | Interface | Autenticação com o registro ECR |
| ECR DKR | Interface | Pull de imagens Docker |
| STS | Interface | `AssumeRoleWithWebIdentity` para IRSA |
| EC2 | Interface | vpc-cni chama EC2 para alocar prefixos `/28` nas ENIs |

Um security group dedicado (`vpc-endpoints-`) permite HTTPS (443) de qualquer IP dentro da VPC para todos os endpoints Interface.

### EKS — `eks.tf`

| Parâmetro | Valor |
|---|---|
| Módulo | `terraform-aws-modules/eks/aws` v20.8.4 |
| Versão Kubernetes | `1.34` |
| Endpoint público | habilitado |
| Endpoint privado | habilitado |
| IRSA | habilitado (`enable_irsa = true`) |

**Addon vpc-cni**
Configurado com `before_compute = true` para que prefix delegation esteja ativo antes do primeiro node inicializar. Parâmetros: `ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1` (mantém um bloco `/28` reservado por node para starts rápidos de pod).

**Controle de acesso**
Usa EKS Access Entries (não o `aws-auth` ConfigMap, que é legado e sujeito a erros manuais). Os IAM principals em `eks_admin_principal_arns` recebem `AmazonEKSClusterAdminPolicy` com escopo de cluster. As entradas são criadas no mesmo job que o cluster para que `infra-resources` já consiga autenticar.

### IAM — `iam.tf`

| Recurso | Finalidade |
|---|---|
| `aws_iam_role.node` | Role assumida pelos EC2 worker nodes |
| `node_worker` | `AmazonEKSWorkerNodePolicy` — kubelet e APIs EC2 |
| `node_cni` | `AmazonEKS_CNI_Policy` — vpc-cni para ENI e prefixos |
| `node_ecr` | `AmazonEC2ContainerRegistryReadOnly` — pull de imagens |
| `module.alb_irsa_role` | IRSA role para o AWS Load Balancer Controller |

A role do ALB Controller é criada aqui (não em `infra-resources`) porque o ARN é necessário como variável pelo job `apps` no CI, e o CI lê outputs apenas do job `infra-cluster` para essa finalidade.

A política IAM do ALB Controller está em [`iam_policy.json`](iam_policy.json) e cobre `elasticloadbalancing:*`, `ec2:Describe*`, `acm:*`, `wafv2:*` e `shield:*`.

### Security Group — `sg.tf`

Security group adicional (`all_worker_management`) anexado a todos os worker nodes via launch template em `infra-resources`. Permite:

- **Ingress:** qualquer protocolo dos ranges RFC-1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`)
- **Egress:** irrestrito (`0.0.0.0/0`)

---

## Variáveis

| Variável | Padrão | Descrição |
|---|---|---|
| `aws_region` | `us-east-2` | Região AWS |
| `kubernetes_version` | `1.34` | Versão do Kubernetes |
| `vpc_cidr` | `10.0.0.0/16` | CIDR da VPC |
| `eks_admin_principal_arns` | ARNs do usuário e root da conta | IAM principals com acesso cluster-admin |

---

## Outputs

| Output | Descrição |
|---|---|
| `cluster_name` | Nome gerado do cluster (sufixo aleatório) |
| `cluster_endpoint` | URL da API do EKS |
| `cluster_ca` | Certificado CA do cluster (base64) |
| `cluster_security_group_id` | SG do plano de controle |
| `node_security_group_id` | SG dos nodes gerenciado pelo módulo EKS |
| `node_role_arn` | ARN da role IAM dos worker nodes |
| `private_subnets` | IDs das subnets privadas (lista) |
| `worker_mgmt_sg_id` | SG adicional de gerenciamento dos workers |
| `alb_irsa_role` | ARN da IRSA role do AWS Load Balancer Controller |
| `oidc_provider` | URL do OIDC provider (sem `https://`) |
| `oidc_provider_arn` | ARN do OIDC provider |
| `vpc_id` | ID da VPC |
| `aws_region` | Região AWS |

---

## Deploy

```bash
cd infra-cluster
terraform init
terraform apply
```

Após o apply, anote os outputs — eles são passados como variáveis de entrada para `infra-resources`.

```bash
terraform output cluster_name
terraform output cluster_endpoint
terraform output cluster_ca
```

No CI, o job `infra-cluster` exporta esses valores como outputs de step, que são consumidos automaticamente pelos jobs seguintes.

---

## Decisões de Design

**Prefix delegation ativado antes dos nodes**
`before_compute = true` no addon vpc-cni garante que a configuração de prefix delegation esteja em vigor antes que qualquer node inicialize. Sem isso, os primeiros pods podem falhar ao aguardar IPs disponíveis.

**EKS Access Entries em vez de `aws-auth`**
O `aws-auth` ConfigMap é um mecanismo legado: edições manuais incorretas podem revogar acesso administrativo ao cluster sem possibilidade de recuperação pela API. Access Entries são gerenciadas via API do EKS e auditadas pelo CloudTrail.

**Um NAT Gateway por AZ**
Aumenta custo em relação a um NAT Gateway único, mas elimina o single point of failure e evita cobrança de tráfego cross-AZ (que ocorreria se nodes de uma AZ roteassem pelo NAT Gateway de outra).

**VPC Endpoints para S3, ECR, STS e EC2**
Sem esses endpoints, todo o tráfego de bootstrap — pull de imagens, troca de tokens IRSA, chamadas EC2 do vpc-cni — passaria pelo NAT Gateway, gerando custo por GB processado. Os endpoints Interface têm custo fixo por hora, mas pagam-se a si mesmos em clusters com pull frequente de imagens.
