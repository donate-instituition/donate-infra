variable "aws_region" {
  description = "AWS region where the S3 bucket will be created"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be one of: dev, staging, production"
  }
}

variable "bucket_name_prefix" {
  description = "Prefix for the S3 bucket name. Final name: {prefix}-{environment}"
  type        = string
  default     = "elodoar-storage"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,35}[a-z0-9]$", var.bucket_name_prefix))
    error_message = "bucket_name_prefix must be 3-37 lowercase alphanumeric/hyphen characters, starting and ending with alphanumeric"
  }
}

variable "enable_versioning" {
  description = "Enable S3 bucket versioning. Increases storage cost but allows object recovery."
  type        = bool
  default     = false
}

variable "receipts_transition_days" {
  description = "Days after creation to transition receipts/ objects to Intelligent-Tiering"
  type        = number
  default     = 30

  validation {
    condition     = var.receipts_transition_days >= 1
    error_message = "receipts_transition_days must be at least 1"
  }
}

variable "abort_multipart_days" {
  description = "Days after which incomplete multipart uploads are aborted"
  type        = number
  default     = 7

  validation {
    condition     = var.abort_multipart_days >= 1
    error_message = "abort_multipart_days must be at least 1"
  }
}

# =============================================================================
# EC2 Single Instance Deploy Variables
# =============================================================================

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH into the EC2 instance (e.g., '203.0.113.0/32')"
  type        = string

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0))
    error_message = "ssh_allowed_cidr must be a valid CIDR block (e.g., '203.0.113.0/32')"
  }
}

variable "domain_name" {
  description = "Domain name for Caddy reverse proxy HTTPS (e.g., 'api.vortely.com')"
  type        = string

  validation {
    condition     = length(var.domain_name) > 0
    error_message = "domain_name must not be empty"
  }
}

variable "alert_email" {
  description = "Email address for AWS Budget alert notifications"
  type        = string

  validation {
    condition     = length(var.alert_email) > 0
    error_message = "alert_email must not be empty"
  }
}

variable "mongodb_uri" {
  description = "MongoDB Atlas connection string"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret"
  type        = string
  sensitive   = true
}

variable "stripe_secret_key" {
  description = "Stripe API secret key"
  type        = string
  sensitive   = true
}

variable "stripe_webhook_secret" {
  description = "Stripe webhook signing secret"
  type        = string
  sensitive   = true
}

variable "resend_api_key" {
  description = "Resend email API key"
  type        = string
  sensitive   = true
}

variable "redis_password" {
  description = "Redis AUTH password"
  type        = string
  sensitive   = true
}

variable "rabbitmq_password" {
  description = "RabbitMQ default user password"
  type        = string
  sensitive   = true
}

variable "firebase_service_account_json" {
  description = "Firebase service account JSON for push notifications"
  type        = string
  sensitive   = true
}
