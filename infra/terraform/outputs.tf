output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name}${var.aws_profile == null ? "" : " --profile ${var.aws_profile}"}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.demo.repository_url
}

output "vpc_id" {
  value = local.vpc_id
}
