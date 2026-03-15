# ps-sl — Camada de Infraestrutura

Este diretório contém todo o código Terraform que provisiona a fundação AWS sobre a qual o cluster é executado. Deve ser aplicado **antes** da camada `apps/`. Tudo aqui é infraestrutura cloud com estado — tome cuidado com destruições.

## O que é criado

```
Conta AWS
└── VPC (10.0.0.0/16)
    ├── Subnets públicas   [10.0.4.0/24, 10.0.5.0/24]  — ALB fica aqui
    │   └── Internet Gateway
    ├── Subnets privadas   [10.0.1.0/24, 10.0.2.0/24]  — nodes ficam aqui
    │   └── NAT Gateway (único, na primeira AZ)
    └── Cluster EKS (ps-sl-eks-<random8>)
        ├── Control Plane Gerenciado
        ├── Node Group Gerenciado  (t3.medium × 2, escala até 6)
        ├── OIDC Identity Provider
        ├── Addon EBS CSI Driver
        └── IAM
            ├── EBS CSI Driver Role   (IRSA)
            └── ALB Controller Role   (IRSA)
```

---

## Recursos

### VPC — [vpc.tf](vpc.tf)

| Atributo | Valor |
|---|---|
| Módulo | `terraform-aws-modules/vpc/aws` v5.7.0 |
| CIDR | `10.0.0.0/16` (configurável via `var.vpc_cidr`) |
| Subnets públicas | `10.0.4.0/24`, `10.0.5.0/24` |
| Subnets privadas | `10.0.1.0/24`, `10.0.2.0/24` |
| NAT Gateway | Único (otimizado para custo; ponto único de falha para saída) |
| DNS hostnames | Habilitado — obrigatório para EKS e ALB |

**A tagueação das subnets** é fundamental para que o AWS Load Balancer Controller descubra onde posicionar os ALBs:

- Subnets públicas: `kubernetes.io/role/elb = 1` → ALBs voltados para internet
- Subnets privadas: `kubernetes.io/role/internal-elb = 1` → ALBs internos
- Ambas: `kubernetes.io/cluster/<nome> = shared` → propriedade do cluster

O nome do cluster inclui um sufixo aleatório de 8 caracteres (`ps-sl-eks-<sufixo>`) gerado no momento do apply para evitar colisões de nomes entre ambientes.

---

### Security Group — [sg.tf](sg.tf)

**`all_worker_mgmt`** — anexado a todos os worker nodes via `eks_managed_node_group_defaults`.

| Direção | Protocolo | Portas | Origem/Destino |
|---|---|---|---|
| Ingress | Todos | Todos | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` |
| Egress | Todos | Todos | `0.0.0.0/0` |

O ingress libera todo o tráfego dos três ranges RFC privados — isso cobre tráfego interno à VPC (pod-to-pod, control-plane-to-node) e qualquer VPN ou rede pareada nos ranges privados padrão. O egress é totalmente aberto para que os nodes possam baixar imagens de contêiner e acessar APIs da AWS.

> Nota: O módulo EKS também cria automaticamente seu próprio security group de cluster. Este SG é suplementar, adicionado por cima.

---

### Cluster EKS — [eks-cluster.tf](eks-cluster.tf)

**Módulo**: `terraform-aws-modules/eks/aws` v20.8.4

| Atributo | Valor |
|---|---|
| Versão Kubernetes | 1.32 |
| Região | `us-east-2` |
| Acesso ao control plane | Endpoints público + privado |
| IRSA | Habilitado (`enable_irsa = true`) |
| Posicionamento dos nodes | Apenas subnets privadas |

#### Node Group Gerenciado

| Atributo | Valor |
|---|---|
| Tipo de instância | `t3.medium` (2 vCPU, 4 GiB RAM) |
| AMI | `AL2_x86_64` (Amazon Linux 2) |
| Min / Desejado / Máx | 2 / 2 / 6 |
| Escalonamento | Manual — nenhum cluster autoscaler configurado |

Os nodes rodam em subnets privadas. O acesso à internet para saída passa pelo NAT Gateway para pulls de imagem e chamadas à API da AWS. Os endpoints do control plane são tanto públicos (para `kubectl` de fora da VPC) quanto privados (para comunicação node-to-plane dentro da VPC).

#### Acesso Admin ao EKS

`var.eks_admin_principal_arns` é uma lista de ARNs de principais IAM que recebem `AmazonEKSClusterAdminPolicy` com escopo no cluster. Isso é feito via `aws_eks_access_entry` + `aws_eks_access_policy_association`, que usa a API de Access Entries do EKS (Kubernetes 1.23+) em vez do `aws-auth` ConfigMap legado. Adicione o ARN do seu usuário ou role IAM aqui para obter acesso `kubectl` sem passos manuais.

#### Addon EBS CSI Driver

O addon `aws-ebs-csi-driver` (v1.29.1-eksbuild.1) é instalado como addon gerenciado do EKS. Ele habilita o provisionamento dinâmico de volumes EBS para `PersistentVolumeClaims`. O addon roda com a IRSA role `ebs_csi_driver_role` (veja a seção IAM). Sem este addon, PVCs usando o provisioner `ebs.csi.aws.com` ficariam em estado `Pending`.

> A StorageClass de `apps/` usa o provisioner **in-tree** `kubernetes.io/aws-ebs` em vez de `ebs.csi.aws.com` para evitar um problema conhecido onde PVCs podem travar quando o pod do CSI driver ainda não foi agendado. Tanto o addon quanto o driver in-tree estão disponíveis — o in-tree é usado por confiabilidade.

---

### IAM — [iam.tf](iam.tf)

Ambas as roles IAM usam **IRSA (IAM Roles for Service Accounts)** — sem credenciais estáticas, sem permissões amplas de instance profile.

#### EBS CSI Driver Role

| Atributo | Valor |
|---|---|
| Nome da role | `AmazonEKS_EBS_CSI_DriverRole` |
| Policy | AWS managed `AmazonEBSCSIDriverPolicy` |
| Escopo de confiança | Apenas `kube-system:ebs-csi-controller-sa` |
| Mecanismo | `sts:AssumeRoleWithWebIdentity` via OIDC |

Permite que o pod do EBS CSI controller (e somente ele) chame `ec2:CreateVolume`, `ec2:AttachVolume`, `ec2:DeleteVolume`, etc. em nome de operações de PVC.

#### ALB Controller Role

| Atributo | Valor |
|---|---|
| Nome da role | `eks-alb-controller` |
| Módulo | `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks` v5.x |
| Policy | Policy customizada de `iam_policy.json` (policy ALB controller prescrita pela AWS) |
| Escopo de confiança | Apenas `kube-system:aws-load-balancer-controller` |

Permite que o pod do ALB controller crie e gerencie Application Load Balancers, target groups, listeners e regras de security group em resposta a recursos `Ingress` do Kubernetes. O ARN da role é passado como output Terraform para a camada `apps/`, que anota a service account do controller com ele.

---

### Outputs — [outputs.tf](outputs.tf)

A camada `apps/` lê estes outputs via Terraform remote state:

| Output | Usado por |
|---|---|
| `cluster_name` | providers de `apps/` (helm, kubernetes) |
| `cluster_endpoint` | providers de `apps/` |
| `cluster_ca` | providers de `apps/` |
| `oidc_provider_arn` | Não consumido diretamente por apps (usado dentro de infra para IRSA) |
| `alb_irsa_role` | Injetado nos values do ALB controller como anotação de service account |
| `region` | providers de `apps/` |

---

### Variáveis — [variables.tf](variables.tf)

| Variável | Padrão | Descrição |
|---|---|---|
| `kubernetes_version` | `1.32` | Versão do control plane do EKS |
| `vpc_cidr` | `10.0.0.0/16` | Espaço de endereços da VPC |
| `aws_region` | `us-east-2` | Região AWS de destino |
| `eks_admin_principal_arns` | Dois ARNs (Felipe + root) | Principais IAM com acesso admin ao cluster |

Para sobrescrever, crie um arquivo `terraform.tfvars` ou passe flags `-var`:
```hcl
# terraform.tfvars
aws_region               = "us-west-2"
eks_admin_principal_arns = ["arn:aws:iam::123456789012:user/voce"]
```

---

## Deploy

```bash
cd infra
terraform init
terraform plan
terraform apply
```

Após o apply, configure o `kubectl`:
```bash
aws eks update-kubeconfig \
  --region us-east-2 \
  --name $(terraform output -raw cluster_name)
```

Verifique se os nodes estão prontos:
```bash
kubectl get nodes
```

Em seguida, prossiga para `apps/`:
```bash
cd ../apps
terraform init
terraform apply
```

---

## Destruição

Destrua os apps primeiro (os Helm releases criam recursos AWS como ALBs que precisam ser limpos antes que a VPC possa ser deletada):
```bash
cd apps  && terraform destroy
cd ../infra && terraform destroy
```

Pular a destruição dos apps primeiro deixará ALBs e ENIs órfãos que bloqueiam a exclusão da VPC.
