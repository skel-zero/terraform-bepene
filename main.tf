data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_key_pair" "deployer" {
  key_name   = "saopaulo-ssh"
  public_key = var.public_key
}

resource "aws_security_group" "vpn_sg" {
  name        = "wireguard-bepene-sg"
  description = "Allow WireGuard and SSH"

  ingress {
    description = "WireGuard UDP"
    from_port   = 443
    to_port     = 443
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

/* not needed for now   
ingress {
    description = "SSH Access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  } */

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "instance" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.nano"
  key_name      = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.vpn_sg.id]

  user_data = templatefile("${path.module}/setup.tpl", {
    domain = local.full_domain
  })

  tags = {
    Name = "Bepene"
  }
}

resource "aws_globalaccelerator_accelerator" "accelerator" {
  name            = "Bepene"
  ip_address_type = "IPV4"
  enabled         = true

  attributes {
    flow_logs_enabled   = false
  }

}

resource "aws_globalaccelerator_listener" "listener" {
  accelerator_arn = aws_globalaccelerator_accelerator.accelerator.arn
  protocol        = "UDP"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "endpoint_group" {
  listener_arn = aws_globalaccelerator_listener.listener.arn
  endpoint_group_region = "sa-east-1"

  endpoint_configuration {
    endpoint_id = aws_instance.instance.id
    weight      = 255
    client_ip_preservation_enabled = true
  }
}


data "aws_route53_zone" "selected" {
  zone_id = var.zone_id
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.full_domain
  type    = "A"
  ttl     = 180
  records = [aws_globalaccelerator_accelerator.accelerator.ip_sets[0].ip_addresses[0]]
}