# Optional: lets .github/workflows/image-push.yml push to ECR via GitHub OIDC.
# Off by default. Only one GitHub OIDC provider can exist per account; set
# create_github_oidc_provider = false if the account already has one.

locals {
  github_oidc_url = "token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.enable_github_oidc && var.create_github_oidc_provider ? 1 : 0
  url            = "https://${local.github_oidc_url}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc && !var.create_github_oidc_provider ? 1 : 0
  url   = "https://${local.github_oidc_url}"
}

resource "aws_iam_role" "github_image_push" {
  count = var.enable_github_oidc ? 1 : 0
  name  = "${var.cluster_name}-github-image-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
      }
      Condition = {
        StringEquals = {
          "${local.github_oidc_url}:aud" = "sts.amazonaws.com"
          "${local.github_oidc_url}:sub" = "repo:${var.github_repository}:ref:refs/heads/${var.github_push_branch}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_image_push" {
  count = var.enable_github_oidc ? 1 : 0
  name  = "ecr-push"
  role  = aws_iam_role.github_image_push[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.demo.arn
      },
    ]
  })
}
