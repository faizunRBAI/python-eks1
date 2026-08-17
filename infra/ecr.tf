resource "aws_ecr_repository" "this" {
  name = var.project_name

  # MUTABLE on purpose: a re-run of the pipeline on the same commit pushes the
  # same commit-sha tag, and an immutable repository would reject it — turning
  # every retry into a failed build.
  image_tag_mutability = "MUTABLE"

  # Lets `terraform destroy` remove the repository together with its images
  # instead of stopping the teardown.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the 20 most recent images; older ones are unreachable history."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}
