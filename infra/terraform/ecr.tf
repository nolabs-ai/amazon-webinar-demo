resource "aws_ecr_repository" "demo" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "demo" {
  repository = aws_ecr_repository.demo.name
  policy = jsonencode({
    rules = [
      {
        # scripts/freeze-image.sh tags the rehearsed image frozen-<date>. An image
        # that matches this rule is not evaluated by the rule below, so the image
        # the webinar runs is never expired by newer test builds.
        rulePriority = 1
        description  = "Keep frozen images (effectively forever)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["frozen-"]
          countType     = "imageCountMoreThan"
          countNumber   = 100
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 20 other images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}
