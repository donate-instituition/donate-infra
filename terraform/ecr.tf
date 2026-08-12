# =============================================================================
# ECR Repositories
# =============================================================================

resource "aws_ecr_repository" "donate_server" {
  name                 = "elodoar/donate-server"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_ecr_repository" "donate_workers" {
  name                 = "elodoar/donate-workers"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# ECR Lifecycle Policies — retain only 5 most recent images
# =============================================================================

resource "aws_ecr_lifecycle_policy" "donate_server" {
  repository = aws_ecr_repository.donate_server.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only 5 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "donate_workers" {
  repository = aws_ecr_repository.donate_workers.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only 5 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
