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
