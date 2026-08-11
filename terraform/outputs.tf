output "S3_BUCKET" {
  description = "Name of the provisioned S3 bucket"
  value       = aws_s3_bucket.this.id
  sensitive   = false
}

output "S3_REGION" {
  description = "AWS region where the S3 bucket was created"
  value       = var.aws_region
  sensitive   = false
}

output "S3_ACCESS_KEY_ID" {
  description = "IAM access key ID for S3 programmatic access"
  value       = aws_iam_access_key.this.id
  sensitive   = true
}

output "S3_SECRET_ACCESS_KEY" {
  description = "IAM secret access key for S3 programmatic access"
  value       = aws_iam_access_key.this.secret
  sensitive   = true
}

output "S3_ENDPOINT" {
  description = "S3 endpoint URL. Only needed for non-AWS S3-compatible providers (e.g., MinIO, LocalStack). Leave empty for real AWS."
  value       = ""
  sensitive   = false
}
