# =============================================================================
# Security Group — EC2 Instance Network Access
# =============================================================================

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "ec2" {
  name        = "elodoar-ec2-${var.environment}"
  description = "Security group for elodoar EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name        = "elodoar-ec2-${var.environment}"
    Project     = "elodoar"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Ingress: HTTP (port 80) from anywhere
resource "aws_security_group_rule" "ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2.id
  description       = "Allow HTTP traffic from anywhere"
}

# Ingress: HTTPS (port 443) from anywhere
resource "aws_security_group_rule" "ingress_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2.id
  description       = "Allow HTTPS traffic from anywhere"
}

# Ingress: SSH (port 22) from restricted CIDR only
resource "aws_security_group_rule" "ingress_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_allowed_cidr]
  security_group_id = aws_security_group.ec2.id
  description       = "Allow SSH from operator CIDR only"
}

# Egress: All outbound traffic (required for Atlas, Stripe, Resend, ECR, SSM, Let's Encrypt)
resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2.id
  description       = "Allow all outbound traffic"
}
