# =============================================================================
# EC2 Instance, Elastic IP, and SSH Key Pair
# =============================================================================

# -----------------------------------------------------------------------------
# Latest Amazon Linux 2023 AMI (resolved via SSM public parameter)
# -----------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# -----------------------------------------------------------------------------
# SSH Key Pair (generated via TLS provider)
# -----------------------------------------------------------------------------

resource "tls_private_key" "ec2" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2" {
  key_name   = "elodoar-ec2-${var.environment}"
  public_key = tls_private_key.ec2.public_key_openssh

  tags = {
    Name        = "elodoar-ec2-${var.environment}"
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# EC2 Instance
# -----------------------------------------------------------------------------

resource "aws_instance" "main" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = "t3.small"
  key_name               = aws_key_pair.ec2.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name        = "elodoar-ec2-root-${var.environment}"
      Project     = "elodoar"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/user_data.sh", {
    environment = var.environment
    aws_region  = var.aws_region
    domain_name = var.domain_name
  }))

  tags = {
    Name        = "elodoar-ec2-${var.environment}"
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# -----------------------------------------------------------------------------
# Elastic IP (persists across instance stop/start cycles)
# -----------------------------------------------------------------------------

resource "aws_eip" "main" {
  instance = aws_instance.main.id
  domain   = "vpc"

  tags = {
    Name        = "elodoar-eip-${var.environment}"
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
