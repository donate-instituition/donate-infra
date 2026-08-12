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

# =============================================================================
# EC2, ECR, and SSH Outputs
# =============================================================================

output "ec2_elastic_ip" {
  description = "Public Elastic IP for DNS A record configuration"
  value       = aws_eip.main.public_ip
  sensitive   = false
}

output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.main.id
  sensitive   = false
}

output "ecr_server_url" {
  description = "ECR repository URL for donate-server"
  value       = aws_ecr_repository.donate_server.repository_url
  sensitive   = false
}

output "ecr_workers_url" {
  description = "ECR repository URL for donate-workers"
  value       = aws_ecr_repository.donate_workers.repository_url
  sensitive   = false
}

output "ssh_private_key" {
  description = "SSH private key for EC2 access (PEM format)"
  value       = tls_private_key.ec2.private_key_pem
  sensitive   = true
}
