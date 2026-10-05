# Launch template values come from ../nested-virtualization-launch-template.json.
locals {
  lt      = jsondecode(file("${path.module}/../nested-virtualization-launch-template.json"))
  lt_disk = local.lt.BlockDeviceMappings[0]
}

resource "aws_launch_template" "kata" {
  name_prefix = "${var.cluster_name}-kata-"

  block_device_mappings {
    device_name = local.lt_disk.DeviceName
    ebs {
      volume_size           = local.lt_disk.Ebs.VolumeSize
      volume_type           = local.lt_disk.Ebs.VolumeType
      encrypted             = local.lt_disk.Ebs.Encrypted
      delete_on_termination = local.lt_disk.Ebs.DeleteOnTermination
    }
  }

  cpu_options {
    nested_virtualization = local.lt.CpuOptions.NestedVirtualization
  }

  metadata_options {
    http_endpoint               = local.lt.MetadataOptions.HttpEndpoint
    http_tokens                 = local.lt.MetadataOptions.HttpTokens
    http_put_response_hop_limit = local.lt.MetadataOptions.HttpPutResponseHopLimit
  }

  user_data = base64encode(templatefile("${path.module}/templates/kata-node-userdata.tftpl", {
    guest_kernel_s3_uri = var.kata_guest_kernel_s3_uri
    region              = var.region
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-kata" }
  }

  # The managed node group selects the AMI and instance type.
}

resource "aws_eks_node_group" "kata" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "kata"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = local.subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = [var.kata_instance_type]

  launch_template {
    id      = aws_launch_template.kata.id
    version = aws_launch_template.kata.latest_version
  }

  scaling_config {
    min_size     = var.kata_min_size
    desired_size = var.kata_desired_size
    max_size     = var.kata_max_size
  }

  # Must match infra/kata-values.yaml and k8s/job.yaml.
  labels = {
    "katacontainers.io/kata-runtime" = "true"
  }

  taint {
    key    = "kata"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.this]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
