# =============================================================================
# SSM Parameter Store — Application Secrets
# =============================================================================

locals {
  ssm_parameters = {
    MONGODB_URI                   = var.mongodb_uri
    JWT_SECRET                    = var.jwt_secret
    STRIPE_SECRET_KEY             = var.stripe_secret_key
    STRIPE_WEBHOOK_SECRET         = var.stripe_webhook_secret
    RESEND_API_KEY                = var.resend_api_key
    REDIS_PASSWORD                = var.redis_password
    RABBITMQ_DEFAULT_PASS         = var.rabbitmq_password
    FIREBASE_SERVICE_ACCOUNT_JSON = var.firebase_service_account_json
  }
}

resource "aws_ssm_parameter" "secrets" {
  for_each = local.ssm_parameters

  name  = "/elodoar/${var.environment}/${each.key}"
  type  = "SecureString"
  value = each.value

  tags = {
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
