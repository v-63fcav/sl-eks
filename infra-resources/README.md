# infra-resources

Segunda camada do cluster. Depende dos outputs de `infra-cluster` via remote state do S3 e provisiona os worker nodes, o addon EBS CSI Driver e a StorageClass padrão do cluster.

Esta camada usa tanto o provider `aws` (node group, addon, IAM) quanto o provider `kubernetes` (StorageClass via `kubernetes_manifest`), por isso recebe `kube_host` e `kube_ca` como variáveis, que são passadas pelo CI a partir dos outputs de `infra-cluster`.

---

## 📋 Índice

1. [Visão Geral da Arquitetura](#visão-geral-da-arquitetura)
2. [Recursos](#recursos)
   - [Node Group](#node-group--node-grouptf)
   - [EBS CSI Driver](#ebs-csi-driver--addonstf--iamtf)
   - [StorageClass gp3](#storageclass-gp3--storagetf)
3. [Dependências de Infraestrutura](#dependências-de-infraestrutura)
4. [Detalhamento Técnico](#detalhamento-técnico)
   - [Launch Template e Security Groups](#launch-template-e-security-groups)
   - [IRSA do EBS CSI Driver](#irsa-do-ebs-csi-driver)
   - [Ordem de Criação dos Recursos](#ordem-de-criação-dos-recursos)
5. [Variáveis](#variáveis)
6. [Outputs](#outputs)
7. [Como Verificar](#como-verificar)
8. [Deploy](#deploy)

---

## 🏗️ Visão Geral da Arquitetura

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  infra-cluster (remote state)          infra-resources (esta camada)          │
│                                                                               │
│  cluster_name ──────────────────────►  aws_eks_node_group.main               │
│  node_security_group_id ────────────►  aws_launch_template.node_group        │
│  worker_mgmt_sg_id ─────────────────►  aws_launch_template.node_group        │
│  node_role_arn ─────────────────────►  aws_eks_node_group.main               │
│  private_subnets ───────────────────►  aws_eks_node_group.main               │
│  oidc_provider_arn ─────────────────►  aws_iam_role.ebs_csi_driver (trust)   │
│  oidc_provider ─────────────────────►  aws_iam_role.ebs_csi_driver (subject) │
│                                                                               │
│  Recursos criados:                                                            │
│                                                                               │
│  ┌────────────────────┐   ┌──────────────────────────┐                       │
│  │   Node Group       │   │   EBS CSI Driver          │                       │
│  │   t3.medium ×2–6   │   │   Addon + IRSA role       │                       │
│  │   AL2023           │   │   AmazonEBSCSIDriverPolicy│                       │
│  └────────────────────┘   └──────────────────────────┘                       │
│                                                                               │
│  ┌────────────────────────────────────────────┐                              │
│  │   StorageClass gp3                          │                              │
│  │   provisioner: ebs.csi.aws.com             │                              │
│  │   encrypted · Retain · WaitForFirstConsumer│                              │
│  └────────────────────────────────────────────┘                              │
│                                                                               │
│  S3: ps-sl-state-bucket-cavi-2  (infra-resources/terraform.tfstate)          │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

## 📦 Recursos

### 💻 Node Group — `node-group.tf`

| Parâmetro | Valor |
|---|---|
| Tipo | Managed Node Group (EKS gerenciado) |
| AMI | `AL2023_x86_64_STANDARD` |
| Tipo de instância | `t3.medium` (2 vCPU, 4 GiB) |
| Escalamento | min 2 / max 6 / desired 2 |
| Subnets | Privadas (3 AZs, do remote state de `infra-cluster`) |
| Role IAM | `node_role_arn` do remote state |

**Launch Template**

O launch template não define AMI, instance type, userData nem nenhuma configuração de boot — esses parâmetros são todos gerenciados pelo EKS (vantagem do Managed Node Group). A única responsabilidade do launch template é anexar os security groups corretos:

```
vpc_security_group_ids:
  ├── node_security_group_id   ← SG principal do cluster (gerenciado pelo módulo EKS)
  └── worker_mgmt_sg_id        ← SG adicional de gerenciamento (sg.tf de infra-cluster)
```

**Configuração de Scaling**

| Parâmetro | Valor | Descrição |
|---|---|---|
| `min_size` | 2 | Mínimo de nodes ativos — garante HA mínima com 2 AZs de cobertura |
| `max_size` | 6 | Limite para escala horizontal |
| `desired_size` | 2 | Estado inicial e padrão de reconciliação |

> **Nota (Roadmap P0):** sem Cluster Autoscaler ou Karpenter, o node group não escala reativamente. O `desired_size` permanece em 2 independente da carga nos pods.

### 💾 EBS CSI Driver — `addons.tf` + `iam.tf`

O EBS CSI Driver é instalado como addon gerenciado pelo EKS (não via Helm), o que delega à AWS o gerenciamento de atualizações de compatibilidade com a versão do Kubernetes.

| Parâmetro | Valor |
|---|---|
| Addon | `aws-ebs-csi-driver` |
| Versão | `v1.29.1-eksbuild.1` |
| Namespace | `kube-system` |
| Service account | `ebs-csi-controller-sa` |

**IRSA Role**

```
Nome: AmazonEKS_EBS_CSI_DriverRole

Trust policy:
  Principal: oidc_provider_arn (remote state)
  Action: sts:AssumeRoleWithWebIdentity
  Condition:
    StringEquals:
      <oidc_provider>:sub = system:serviceaccount:kube-system:ebs-csi-controller-sa

Política: AmazonEBSCSIDriverPolicy (gerenciada pela AWS)
  ├── ec2:CreateVolume, ec2:DeleteVolume
  ├── ec2:AttachVolume, ec2:DetachVolume
  ├── ec2:DescribeVolumes, ec2:DescribeSnapshots
  └── ec2:CreateSnapshot (para volume snapshots)
```

A trust policy é scoped à service account específica do controller — nenhuma outra service account no cluster pode assumir esta role.

**Dependência com o Node Group**

```hcl
depends_on = [aws_eks_node_group.main]
```

O addon é criado _após_ o node group estar pronto. Sem nodes disponíveis, o pod do EBS CSI controller ficaria em estado `Pending` indefinidamente.

### 🗄️ StorageClass gp3 — `storage.tf`

| Parâmetro | Valor | Descrição |
|---|---|---|
| `provisioner` | `ebs.csi.aws.com` | Driver CSI do EBS — requer o addon EBS CSI instalado |
| `type` | `gp3` | Volume EBS de nova geração (baseline 3.000 IOPS, 125 MB/s sem custo extra) |
| `encrypted` | `"true"` | Criptografia em repouso com a CMK padrão da conta |
| `reclaimPolicy` | `Retain` | Volume EBS **não** é deletado ao remover o PVC |
| `volumeBindingMode` | `WaitForFirstConsumer` | Volume provisionado apenas quando o pod é agendado em uma AZ |
| `allowVolumeExpansion` | `true` | PVC pode ser expandido via edição do campo `resources.requests.storage` |

**Recurso `kubernetes_manifest` em vez de `kubernetes_storage_class_v1`**

```
kubernetes_storage_class_v1  usa client-side apply → falha se o recurso já existir
kubernetes_manifest           usa server-side apply → adota o recurso se ele já existir
```

`kubernetes_manifest` é idempotente: re-aplicações e migrações de estado Terraform não causam erros de conflito. O Terraform apenas reconcilia o estado desejado com o estado existente no cluster.

---

## 🔗 Dependências de Infraestrutura

Esta camada lê o estado de `infra-cluster` via `remote-state.tf`:

```hcl
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = "ps-sl-state-bucket-cavi-2"
    key    = "infra-cluster/terraform.tfstate"
    region = "us-east-2"
  }
}
```

Mapeamento completo de dependências:

| Output de `infra-cluster` | Recurso em `infra-resources` | Finalidade |
|---|---|---|
| `node_security_group_id` | `aws_launch_template.node_group` | SG principal dos nodes gerenciado pelo módulo EKS |
| `worker_mgmt_sg_id` | `aws_launch_template.node_group` | SG adicional de gerenciamento |
| `node_role_arn` | `aws_eks_node_group.main` | Role IAM que os nodes assumem |
| `private_subnets` | `aws_eks_node_group.main` | Subnets de execução dos nodes |
| `oidc_provider_arn` | `aws_iam_role.ebs_csi_driver` | Principal da trust policy (Federated) |
| `oidc_provider` | `aws_iam_role.ebs_csi_driver` | Condição de subject (`system:serviceaccount:...`) |
| `cluster_name` (via var) | `aws_eks_node_group.main`, `aws_eks_addon` | Nome do cluster para associar os recursos |

---

## 🔬 Detalhamento Técnico

### 🛡️ Launch Template e Security Groups

```
aws_launch_template.node_group
    │
    └── vpc_security_group_ids:
            │
            ├── node_security_group_id  (do remote state de infra-cluster)
            │   Funções:
            │   ├── permite comunicação entre nodes e control plane (porta 443, 10250)
            │   ├── permite comunicação entre pods (todas as portas na subnet /19)
            │   └── gerenciado pelo módulo terraform-aws-modules/eks — não editar manualmente
            │
            └── worker_mgmt_sg_id  (sg.tf de infra-cluster)
                Funções:
                ├── permite acesso SSH/admin de qualquer RFC-1918 (10.0.0.0/8, etc.)
                └── permite egress irrestrito
```

O node group usa `launch_template { id, version }` apontando para a versão mais recente do launch template. Qualquer alteração no launch template gera uma nova versão e o EKS inicia um rolling update dos nodes.

### 🔑 IRSA do EBS CSI Driver

```
Pod do ebs-csi-controller (service account: ebs-csi-controller-sa, namespace: kube-system)
    │
    │  No startup, o pod projetado tem um token JWT em:
    │  /var/run/secrets/eks.amazonaws.com/serviceaccount/token
    │
    ▼
aws sts assume-role-with-web-identity
  RoleArn: arn:aws:iam::<account>:role/AmazonEKS_EBS_CSI_DriverRole
  WebIdentityToken: <JWT do OIDC provider>
    │
    ▼
STS valida:
  1. JWT assinado pelo OIDC provider do cluster (oidc_provider_arn)
  2. JWT contém sub = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
     (condição StringEquals na trust policy)
    │
    ▼
Credenciais temporárias AWS entregues ao pod
    │
    ▼
Controller cria/anexa/detacha volumes EBS via API EC2
```

### 🔢 Ordem de Criação dos Recursos

A ordem de criação dentro desta camada importa — recursos com dependências implícitas ou explícitas:

```
data.terraform_remote_state.cluster  (lê estado do S3 — sem dependência)
        │
        ├── aws_iam_role.ebs_csi_driver         (usa oidc_provider, oidc_provider_arn)
        │       └── aws_iam_role_policy_attachment.ebs_csi_driver
        │
        ├── aws_launch_template.node_group      (usa node_security_group_id, worker_mgmt_sg_id)
        │       └── aws_eks_node_group.main     (usa node_role_arn, private_subnets)
        │               │
        │               └── aws_eks_addon.ebs_csi_driver  (depends_on: node_group)
        │
        └── kubernetes_manifest.gp3_storage_class   (provider k8s — cluster já deve estar acessível)
```

O provider `kubernetes` autentica via `aws eks get-token` usando `var.cluster_name`, que é passada pelo CI após o job `infra-cluster` ter criado o cluster.

---

## 📝 Variáveis

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `aws_region` | `string` | `"us-east-2"` | Região AWS |
| `cluster_name` | `string` | — | Nome do cluster EKS (output de `infra-cluster`) |
| `kube_host` | `string` | — | URL HTTPS da API do EKS (output de `infra-cluster`) |
| `kube_ca` | `string` | — | Certificado CA do cluster em base64 (output de `infra-cluster`) |

`cluster_name`, `kube_host` e `kube_ca` são obrigatórios sem valor padrão. No CI, são injetados como variáveis de ambiente pelo job predecessor.

---

## 📤 Outputs

| Output | Origem | Consumido por | Descrição |
|---|---|---|---|
| `cluster_name` | `var.cluster_name` | apps (CI) | Nome do cluster — repassado para o job `apps` |
| `cluster_endpoint` | `var.kube_host` | apps (CI) | Endpoint da API — repassado para o job `apps` |
| `cluster_ca` | `var.kube_ca` | apps (CI) | CA do cluster — repassado para o job `apps` |
| `alb_irsa_role` | remote state | apps (CI) | ARN da IRSA role do ALB Controller (lido de `infra-cluster`) |
| `vpc_id` | remote state | apps (CI) | ID da VPC (lido de `infra-cluster`) |

---

## ✅ Como Verificar

```bash
# Confirmar nodes Running
kubectl get nodes -o wide
# Esperado: 2 nodes com status Ready, tipo t3.medium

# Confirmar addon EBS CSI Driver ativo
aws eks describe-addon \
  --cluster-name <cluster_name> \
  --addon-name aws-ebs-csi-driver \
  --region us-east-2 \
  --query 'addon.status'
# Esperado: "ACTIVE"

# Confirmar pods do EBS CSI Driver rodando
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# Confirmar StorageClass criada
kubectl get storageclass gp3
kubectl describe storageclass gp3

# Confirmar IRSA da role do EBS CSI
aws iam get-role --role-name AmazonEKS_EBS_CSI_DriverRole \
  --query 'Role.AssumeRolePolicyDocument'

# Testar provisionamento dinâmico de volume (opcional)
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ebs-pvc
spec:
  storageClassName: gp3
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc test-ebs-pvc   # Status: Pending (WaitForFirstConsumer — aguarda pod)
kubectl delete pvc test-ebs-pvc
```

---

## 🚦 Deploy

```bash
cd infra-resources
terraform init

# Valores obtidos dos outputs de infra-cluster
terraform apply \
  -var="cluster_name=$(cd ../infra-cluster && terraform output -raw cluster_name)" \
  -var="kube_host=$(cd ../infra-cluster && terraform output -raw cluster_endpoint)" \
  -var="kube_ca=$(cd ../infra-cluster && terraform output -raw cluster_ca)"
```

No CI, o job `infra-resources` do workflow `tf-deploy.yml` recebe `cluster_name`, `cluster_endpoint` e `cluster_ca` automaticamente como outputs do job `infra-cluster` e os passa como variáveis via `-var`.

Após o apply desta camada, o cluster está pronto para receber Helm releases: nodes ativos, volumes EBS dinâmicos e StorageClass configurada.
