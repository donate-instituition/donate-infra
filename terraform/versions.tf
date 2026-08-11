terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment the block below to use remote state storage.
  # You must first create the S3 bucket and DynamoDB table manually.
  # See README.md "Remote State" section for instructions.
  #
  # backend "s3" {
  #   bucket         = "elodoar-terraform-state"   # Name of the S3 bucket to store Terraform state files
  #   key            = "s3-storage/terraform.tfstate" # Path within the bucket where the state file will be written
  #   region         = "us-east-1"                 # AWS region where the state bucket is located
  #   dynamodb_table = "elodoar-terraform-locks"   # DynamoDB table name used for state locking (must have LockID partition key)
  #   encrypt        = true                        # Enable server-side encryption of the state file at rest
  # }
}
