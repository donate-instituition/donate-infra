# =============================================================================
# EC2 IAM Role, Instance Profile, and Policies
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# IAM Role with EC2 assume-role trust policy
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ec2" {
  name = "elodoar-ec2-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# IAM Instance Profile
# -----------------------------------------------------------------------------

resource "aws_iam_instance_profile" "ec2" {
  name = "elodoar-ec2-${var.environment}"
  role = aws_iam_role.ec2.name

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# SSM Read Policy
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "ec2_ssm" {
  name        = "elodoar-ec2-ssm-${var.environment}"
  description = "Allow EC2 to read SSM parameters under /elodoar/${var.environment}/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSSMGetParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParametersByPath",
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/elodoar/${var.environment}/*"
      }
    ]
  })

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# ECR Pull Policy
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "ec2_ecr" {
  name        = "elodoar-ec2-ecr-${var.environment}"
  description = "Allow EC2 to pull images from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowECRPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/elodoar/*"
      }
    ]
  })

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Policy (Logs + Metrics)
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "ec2_cloudwatch" {
  name        = "elodoar-ec2-cloudwatch-${var.environment}"
  description = "Allow EC2 to write logs and metrics to CloudWatch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:CreateLogGroup"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/elodoar/${var.environment}/*"
      },
      {
        Sid    = "AllowCloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Policy Attachments
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ec2_ssm.arn
}

resource "aws_iam_role_policy_attachment" "ec2_ecr" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ec2_ecr.arn
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ec2_cloudwatch.arn
}
