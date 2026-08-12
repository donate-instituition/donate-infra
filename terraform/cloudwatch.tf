# =============================================================================
# CloudWatch Log Group
# =============================================================================

resource "aws_cloudwatch_log_group" "ec2" {
  name              = "/elodoar/${var.environment}/ec2"
  retention_in_days = 7

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
