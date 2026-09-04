data "aws_vpc" "default" {
  count   = var.ec2_launch ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.ec2_launch ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

data "aws_ssm_parameter" "al2023_ami" {
  count = var.ec2_launch ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "ec2" {
  count       = var.ec2_launch ? 1 : 0
  name        = "ilds-kpi-sg"
  description = "ILDS KPI runner"
  vpc_id      = data.aws_vpc.default[0].id

  dynamic "ingress" {
    for_each = var.ec2_key_name != "" ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.ssh_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "kpi_worker" {
  count                = var.ec2_launch ? 1 : 0
  ami                  = data.aws_ssm_parameter.al2023_ami[0].value
  instance_type        = var.ec2_instance_type
  key_name             = var.ec2_key_name != "" ? var.ec2_key_name : null
  subnet_id            = data.aws_subnets.default[0].ids[0]
  vpc_security_group_ids = [aws_security_group.ec2[0].id]
  iam_instance_profile = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    aws_region   = var.aws_region
    bucket_name  = local.bucket_name
    queue_url    = aws_sqs_queue.ilds.id
    repo_url     = var.repo_url
    deploy_user  = var.deploy_user
  })

  tags = {
    Name = "ilds-garage-kpi-runner"
  }

  # The instance profile needs to exist and be attached before boot for the
  # user-data script's boto3 calls (via the app, not user-data itself) to
  # have credentials immediately. Terraform's dependency graph already
  # orders this correctly via the iam_instance_profile reference above;
  # this is just making the ordering explicit for readability.
  depends_on = [aws_iam_role_policy.ec2]
}
