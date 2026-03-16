# infra-resources

Segunda camada do cluster. Depende dos outputs de `infra-cluster` via remote state do S3 e provisiona o node group EC2, o addon EBS CSI Driver e a StorageClass padrão do cluster.

Esta camada precisa tanto do provider `aws` (para o node group e o addon) quanto do provider `kubernetes` (para a StorageClass), por isso recebe `kube_host` e `kube_ca` como variáveis de entrada vindas do CI.

---

## Recursos Criados

### Node Group — `node-group.tf`

| Parâmetro | Valor |
|---|---|
| Tipo de instância | `t3.medium` |
| AMI | `AL2023_x86_64_STANDARD` |
| Escalamento | min 2 / max 6 / desired 2 |
| Subnets | Subnets privadas de `infra-cluster` (remote state) |
| Launch template | Anexa o SG do cluster + SG de gerenciamento (`worker_mgmt_sg_id`) |

O launch template não configura AMI, instance type nem userData — esses parâmetros são herdados do managed node group do EKS. Sua única função é anexar os security groups corretos.

### EBS CSI Driver — `addons.tf` + `iam.tf`

| Recurso | Detalhe |
|---|---|
| Addon EKS | `aws-ebs-csi-driver` v1.29.1-eksbuild.1 |
| IAM role | `AmazonEKS_EBS_CSI_DriverRole` com IRSA |
| Política AWS | `AmazonEBSCSIDriverPolicy` (gerenciada pela AWS) |
| Trust policy | Vinculada ao OIDC provider de `infra-cluster` via remote state |

O addon depende do node group (`depends_on = [aws_eks_node_group.main]`) para garantir que o pod do controller possa ser agendado imediatamente após a criação.

A trust policy da IRSA role vincula especificamente a service account `kube-system:ebs-csi-controller-sa`, sem conceder acesso a outras service accounts.

### StorageClass gp3 — `storage.tf`

StorageClass `gp3` criada via `kubernetes_manifest` (server-side apply), o que a torna idempotente: se já existir no cluster, o Terraform a adota sem erro.

| Parâmetro | Valor |
|---|---|
| Provisioner | `ebs.csi.aws.com` |
| Tipo de volume EBS | `gp3` |
| Criptografia | habilitada (`encrypted = "true"`) |
| Reclaim policy | `Retain` (volumes não são deletados ao remover o PVC) |
| Volume binding | `WaitForFirstConsumer` |
| Expansão de volume | habilitada |

**`WaitForFirstConsumer`** impede que o EBS seja provisionado em uma AZ antes de o pod que vai usá-lo ser agendado. Sem isso, o volume poderia ser criado em uma AZ diferente da do pod, causando falha de mount.

---

## Dependências de Infraestrutura

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

Outputs consumidos:

| Output de `infra-cluster` | Usado em |
|---|---|
| `node_security_group_id` | Launch template — SG principal dos nodes |
| `worker_mgmt_sg_id` | Launch template — SG adicional de gerenciamento |
| `node_role_arn` | Node group — role IAM dos workers |
| `private_subnets` | Node group — subnets de execução |
| `oidc_provider_arn` | Trust policy da IRSA role do EBS CSI |
| `oidc_provider` | Condição de subject na trust policy |

---

## Variáveis

| Variável | Padrão | Descrição |
|---|---|---|
| `aws_region` | `us-east-2` | Região AWS |
| `cluster_name` | — | Nome do cluster EKS (output de `infra-cluster`) |
| `kube_host` | — | Endpoint da API do EKS |
| `kube_ca` | — | Certificado CA do cluster (base64) |

`cluster_name`, `kube_host` e `kube_ca` não têm valores padrão — precisam ser passados explicitamente.

---

## Outputs

| Output | Origem | Descrição |
|---|---|---|
| `cluster_name` | `var.cluster_name` | Nome do cluster (repassado ao job `apps`) |
| `cluster_endpoint` | `var.kube_host` | Endpoint da API (repassado ao job `apps`) |
| `cluster_ca` | `var.kube_ca` | CA do cluster (repassado ao job `apps`) |
| `alb_irsa_role` | remote state | ARN da IRSA role do ALB Controller |
| `vpc_id` | remote state | ID da VPC |

Os outputs desta camada são consumidos pelo job `apps` no CI.

---

## Deploy

```bash
cd infra-resources
terraform init
terraform apply \
  -var="cluster_name=$(cd ../infra-cluster && terraform output -raw cluster_name)" \
  -var="kube_host=$(cd ../infra-cluster && terraform output -raw cluster_endpoint)" \
  -var="kube_ca=$(cd ../infra-cluster && terraform output -raw cluster_ca)"
```

No CI, os valores são injetados automaticamente a partir dos outputs do job `infra-cluster`.

---

## Decisões de Design

**EBS CSI como addon gerenciado**
Usar o addon gerenciado pelo EKS (em vez de instalar via Helm) garante que a AWS atualize automaticamente o driver em minor versions compatíveis e gerencie o ciclo de vida integrado com o cluster.

**StorageClass com `Retain`**
A política `Retain` evita a exclusão acidental de volumes EBS ao deletar PVCs. Em ambientes de desenvolvimento, isso protege dados de estado de aplicações (Prometheus, Loki, Tempo) durante operações de Terraform. Para liberar o storage, é necessário deletar o volume EBS manualmente após confirmar que os dados não são mais necessários.

**`kubernetes_manifest` para a StorageClass**
O recurso `kubernetes_storage_class_v1` do provider Kubernetes não suporta server-side apply, o que causaria conflito se a StorageClass já existisse no cluster. `kubernetes_manifest` usa server-side apply e é idempotente, tornando o Terraform seguro para re-aplicações e migrações de estado.
