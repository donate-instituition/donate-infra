# =============================================================================
# AWS Budget Alert
# =============================================================================

resource "aws_budgets_budget" "monthly" {
  name         = "elodoar-${var.environment}-monthly"
  budget_type  = "COST"
  limit_amount = "25"
  limit_unit   = "USD"

  time_period_start = "2025-01-01_00:00"
  time_unit         = "MONTHLY"

  # Notification at 80% actual spend
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Notification at 100% forecasted spend
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
