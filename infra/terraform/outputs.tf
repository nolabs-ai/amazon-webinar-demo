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

output "github_image_push_role_arn" {
  description = "Set as the AWS_ROLE_ARN repository variable. Null unless enable_github_oidc is true."
  value       = one(aws_iam_role.github_image_push[*].arn)
}
