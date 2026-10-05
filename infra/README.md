# EKS and Kata infrastructure

`terraform/` provisions an EKS cluster with a dedicated Kata node group, a
system node group, and an ECR repository. `install-kata.sh` installs kata-deploy
on the Kata nodes. OpenTofu works as a drop-in for Terraform 1.8 or newer.

## Resources

| Resource | Details |
|---|---|
| Provider | `allowed_account_ids = [var.aws_account_id]` (required), optional `aws_profile`, region `eu-west-1` |
| VPC | `10.60.0.0/16`, 2 AZs, private and public subnets, one NAT gateway. Set `create_vpc = false` with `vpc_id` and `private_subnet_ids` to use an existing VPC |
| EKS cluster | Kubernetes 1.35, API authentication mode, public endpoint restricted by `public_access_cidrs` |
| `kata` node group | `m8i.xlarge`, Amazon Linux 2023, 0 to 2 nodes, label `katacontainers.io/kata-runtime=true`, taint `kata=true:NoSchedule` |
| `kata` launch template | Built from `nested-virtualization-launch-template.json`: nested virtualization, 100 GiB encrypted gp3, IMDSv2 required |
| `system` node group | `t3.medium`, Amazon Linux 2023, for coredns, kube-proxy, and the CNI |
| ECR | `amazon-webinar-demo`, immutable tags, scan on push, last 20 images kept; node role has pull-only access |

## Prerequisites

- `terraform` or `tofu`, `kubectl`, `helm`, and the AWS CLI.
- A dedicated AWS account with administrator access. Its ID goes in
  `aws_account_id`; the provider refuses to run against any other account.
- An EC2 vCPU quota of at least 12 for "Running On-Demand Standard (A, C, D, H,
  I, M, R, T, Z) instances" (`L-1216C47A`).
- The custom guest kernel uploaded to S3, as described in
  [`../kernel/README.md`](../kernel/README.md).

## Deploy

```text
export AWS_PROFILE=<your-profile>
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # set aws_account_id and kata_guest_kernel_s3_uri
terraform init
terraform plan -out tfplan
terraform apply tfplan

$(terraform output -raw kubeconfig_command)
kubectl get nodes -L katacontainers.io/kata-runtime

cd ../..
infra/install-kata.sh
```

`install-kata.sh` installs the kata-deploy chart (`KATA_CHART_VERSION`, default
3.27.0) with `kata-values.yaml`, waits for the rollout, and confirms the
`kata-clh` RuntimeClass exists.

To push the demo image, use a unique tag because tags are immutable:

```text
ECR=$(terraform -chdir=infra/terraform output -raw ecr_repository_url)
aws ecr get-login-password --region eu-west-1 \
  | docker login --username AWS --password-stdin "${ECR%%/*}"
docker buildx build --platform linux/amd64 -t "$ECR:<tag>" --push .
```

## Guest kernel

The stock Kata 3.27.0 guest kernel has no Landlock, which nono requires.
Three pieces must stay consistent:

1. `terraform/templates/kata-node-userdata.tftpl` downloads the kernel at
   `kata_guest_kernel_s3_uri` to `/opt/kata-guest-kernel/vmlinux-landlock`
   before the kubelet starts. The node role can read only that object.
2. `kata-values.yaml` disables the stock `clh` shim and defines a `kata-clh`
   custom runtime that sets the kernel path. `k8s/job.yaml` is unchanged.
3. `../kernel/versions.env` pins the Kata release the kernel is built from. It
   must match `KATA_CHART_VERSION`.

Without the kernel file, `kata-clh` pods fail to start.

## Teardown

Delete Kubernetes resources first, then:

```text
helm uninstall kata-deploy -n kata-system
cd infra/terraform
terraform destroy
```

State is local and gitignored. Keep it until the destroy finishes.
