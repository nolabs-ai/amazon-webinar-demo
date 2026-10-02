# EKS and Kata infrastructure

This directory records the minimal infrastructure contract for the demo. It
does not create AWS resources yet.

The target cluster has a dedicated x86_64 EKS managed node group for Kata:

- a supported EC2 instance type with nested virtualization enabled;
- Amazon Linux 2023;
- node label `katacontainers.io/kata-runtime=true`;
- node taint `kata=true:NoSchedule`;
- encrypted gp3 root storage; and
- IMDSv2 required.

`nested-virtualization-launch-template.json` is the launch-template data used
when creating that node group. The cluster and node-group definitions will be
added after the AWS account, region, VPC, and cluster ownership are agreed.

Install Kata only on the dedicated nodes:

```text
helm upgrade --install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version 3.27.0 \
  --namespace kata-system \
  --create-namespace \
  --values infra/kata-values.yaml
```

The chart installs the `kata-clh` RuntimeClass used by the demo Job. Versions
must be reviewed and deliberately updated before deployment.
